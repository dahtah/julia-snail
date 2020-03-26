;;; julia-snail.el --- Julia Snail -*- lexical-binding: t -*-


;; URL: https://github.com/gcv/julia-snail
;; Package-Requires: ((emacs "26.2") (cl-lib "0.5") (dash "2.16.0") (julia-mode "0.3") (s "1.12.0") (parsec "0.1.3") (spinner "1.7.3") (vterm "0.0.1"))
;; Version: 1.0.0beta6
;; Created: 2019-10-27

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides an interactive development environment for Julia
;; (https://julialang.org/), similar to SLIME for Common Lisp and CIDER for
;; Clojure. Refer to the README.org file for documentation.

;;; Code:


;;; --- requirements

(require 'cl-lib)
(require 'json)
(require 'rx)
(require 's)
(require 'spinner)
(require 'subr-x)
(require 'thingatpt)
(require 'vterm)
(require 'xref)

(require 'julia-snail-parser)
(require 'julia-snail-history)

;;; --- customization

(defgroup julia-snail nil
  "Customization options for Julia Snail mode."
  :group 'external)

(defcustom julia-snail-executable "julia"
  "Julia executable to run as a Snail server."
  :tag "Julia executable"
  :group 'julia-snail
  :safe 'stringp
  :type 'string)

(defcustom julia-snail-port 10011
  "Default Snail server port."
  :tag "Snail server port"
  :group 'julia-snail
  :safe 'integerp
  :type 'integer)
(make-variable-buffer-local 'julia-snail-port)

(defcustom julia-snail-repl-buffer "*julia*"
  "Default buffer to use for Julia REPL interaction."
  :tag "Julia REPL buffer"
  :group 'julia-snail
  :safe 'stringp
  :type 'string)
(make-variable-buffer-local 'julia-snail-buffer)

(defcustom julia-snail-show-error-window t
  "When t: show compilation errors in separate window. When nil: display errors in the minibuffer."
  :tag "Show compilation errors in separate window"
  :group 'julia-snail
  :type 'boolean)

(defcustom julia-snail-async-timeout 10000
  "When performing asynchronous Snail operations, wait this many milliseconds before timing out."
  :tag "Timeout for asynchronous Snail operations"
  :group 'julia-snail
  :type 'integer)


;;; --- variables

(defvar-local julia-snail--process nil)

(defvar julia-snail--server-file
  (concat (if load-file-name
                (file-name-directory load-file-name)
              (file-name-as-directory default-directory))
          "JuliaSnail.jl"))

;;; TODO: Maybe this should hash by proc+reqid rather than just reqid?
(defvar julia-snail--requests
  (make-hash-table :test #'equal))

(defvar julia-snail--proc-responses
  (make-hash-table :test #'equal))

(defvar julia-snail--cache-proc-names-base
  (make-hash-table :test #'equal))

(defvar julia-snail--cache-proc-names-core
  (make-hash-table :test #'equal))

(defvar julia-snail--repl-go-back-target)


;;; --- Snail protocol request tracking data structure

(cl-defstruct julia-snail--request-tracker
  repl-buf
  originating-buf
  (callback-success (lambda (&optional _data) (message "Snail command succeeded")))
  (callback-failure (lambda () (message "Snail command failed")))
  (display-error-buffer-on-failure? t)
  tmpfile)


;;; --- supporting functions

(defun julia-snail--process-buffer-name (repl-buf)
  "Return the process buffer name for REPL-BUF."
  (let ((real-buf (get-buffer repl-buf)))
    (unless real-buf
      (error "No REPL buffer found"))
    (format "%s process" (buffer-name (get-buffer real-buf)))))

(defun julia-snail--message-buffer (repl-buf name message)
  "Return a buffer named NAME linked to REPL-BUF containing MESSAGE."
  (let ((real-buf (get-buffer repl-buf)))
    (unless real-buf
      (error "No REPL buffer found"))
    (let* ((msg-buf-name (format "%s %s" (buffer-name (get-buffer real-buf)) name))
           (msg-buf (get-buffer-create msg-buf-name)))
      (with-current-buffer msg-buf
        (read-only-mode -1)
        (erase-buffer)
        (insert message)
        (goto-char (point-min))
        (read-only-mode 1)
        (julia-snail-message-buffer-mode))
      msg-buf)))

(defun julia-snail--flash-region (start end &optional timeout)
  "Highlight the region outlined by START and END for TIMEOUT period."
  ;; borrowed from SLIME
  (let ((overlay (make-overlay start end)))
    (overlay-put overlay 'face 'highlight)
    (run-with-timer (or timeout 0.2) nil 'delete-overlay overlay)))

(defun julia-snail--construct-module-path (module)
  "Return a Julia array representing the module path of MODULE as Julia symbols.
MODULE can be:
- nil, which returns [:Main]
- an Elisp keyword, which returns [<keyword>], including the
  leading colon in the keyword
- an Elisp list, which can contain either keywords or strings,
  and which is converted to a Julia array literal with the
  entries of the input list converted to Julia keywords"
  (cond ((null module) "[:Main]")
        ((keywordp module) (format "[%s]" module))
        ((listp module) (format
                         "[%s]"
                         (s-join " " (-map (lambda (s)
                                             (if (keywordp s)
                                                 (format "%s" s)
                                               (format ":%s" s)))
                                           module))))
        (t (error "Malformed module specification"))))

(defmacro julia-snail--with-syntax-table (&rest body)
  "Evaluate BODY with a Snail-specific syntax table."
  (declare (indent defun))
  `(let ((stab (copy-syntax-table)))
     (with-syntax-table stab
       (modify-syntax-entry ?. "_")
       (modify-syntax-entry ?@ "_")
       (modify-syntax-entry ?= " ")
       ,@body)))

(defun julia-snail--identifier-at-point ()
  "Return identifier at point using Snail-specific syntax table."
  (julia-snail--with-syntax-table
    (thing-at-point 'symbol t)))

(defun julia-snail--identifier-at-point-bounds ()
  "Return the bounds of the identifier at point using Snail-specific syntax table."
  (julia-snail--with-syntax-table
    (bounds-of-thing-at-point 'symbol)))

(defmacro julia-snail--wait-while (condition increment maximum)
  "Synchronously wait for CONDITION to evaluate to true.
INCREMENT: polling frequency.
MAXIMUM: max timeout."
  (let ((sleep-total (gensym))
        (incr (gensym))
        (max (gensym)))
    `(let ((,sleep-total 0)
           (,incr ,increment)
           (,max ,maximum))
       (while (and (< ,sleep-total ,max) ,condition)
         (sleep-for 0 ,incr)
         (setf ,sleep-total (+ ,sleep-total ,incr))))))


;;; --- connection management functions

(defun julia-snail--repl-cleanup ()
  "REPL buffer cleanup."
  (let ((process-buf (get-buffer (julia-snail--process-buffer-name (current-buffer)))))
    (when process-buf
      (remhash process-buf julia-snail--cache-proc-names-base)
      (remhash process-buf julia-snail--cache-proc-names-core)
      (kill-buffer process-buf)))
  (setq julia-snail--process nil))

(defun julia-snail--repl-enable ()
  "REPL buffer minor mode initializer."
  (add-hook 'kill-buffer-hook #'julia-snail--repl-cleanup nil t)
  (make-local-variable 'julia-snail--repl-go-back-target)
  (let ((repl-buf (current-buffer))
        (process-buf (get-buffer-create (julia-snail--process-buffer-name (current-buffer)))))
    (when (and (featurep 'perspective) (bound-and-true-p persp-mode)) ; perspective-el support
      (declare-function persp-add-buffer "perspective.el")
      (persp-add-buffer process-buf))
    (when (and (featurep 'persp-mode) (bound-and-true-p persp-mode)) ; persp-mode support
      (declare-function persp-add-buffer "persp-mode.el")
      (declare-function get-current-persp "persp-mode.el")
      (persp-add-buffer process-buf (get-current-persp) nil))
    (with-current-buffer process-buf
      (unless julia-snail--process
        (setq julia-snail-port (buffer-local-value 'julia-snail-port repl-buf))
        ;; XXX: This is currently necessary because there does not appear to be
        ;; a way to pass arguments to an interactive Julia session. This does
        ;; not work: `julia -L JuliaSnail.jl -- $PORT`.
        ;; https://github.com/JuliaLang/julia/issues/10226 refers to this
        ;; problem and supposedly fixes it, but it does not work for me with
        ;; Julia 1.0.4.
        ;; TODO: Follow-up on https://github.com/JuliaLang/julia/issues/33752
        (julia-snail--send-to-repl
          (format "JuliaSnail.start(%d);" julia-snail-port)
          :repl-buf repl-buf
          :async nil)
        ;; connect to the server
        (let ((netstream (let ((attempt 0)
                               (max-attempts 5)
                               (stream nil))
                           (while (and (< attempt max-attempts) (null stream))
                             (cl-incf attempt)
                             (message "Snail connecting to Julia process, attempt %d/5..." attempt)
                             (condition-case nil
                                 (setq stream (open-network-stream "julia-process" process-buf "localhost" julia-snail-port))
                               (error (when (< attempt max-attempts) (sleep-for 0 500)))))
                           stream)))
          (if netstream
              (with-current-buffer repl-buf
                ;; NB: buffer-local variable!
                (setq julia-snail--process netstream)
                (set-process-filter julia-snail--process #'julia-snail--server-response-filter)
                (message "Snail connected to Julia. Happy hacking!"))
            ;; something went wrong
            (error "Failed to connect to Snail server")))))))

(defun julia-snail--repl-disable ()
  "REPL buffer minor mode cleanup."
  (julia-snail--repl-cleanup))

(defun julia-snail--enable ()
  "Source buffer minor mode initializer."
  ;; placeholder
  nil
  )

(defun julia-snail--disable ()
  "Source buffer minor mode cleanup."
  ;; placeholder
  nil
  )


;;; --- Julia REPL and Snail server interaction functions

(cl-defun julia-snail--send-to-repl
    (str
     &key
     (repl-buf (get-buffer julia-snail-repl-buffer))
     (async t))
  "Insert str directly into the REPL buffer. When :async is nil,
wait for the REPL prompt to return, otherwise return immediately."
  (declare (indent defun))
  (unless repl-buf
    (user-error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer))
  (with-current-buffer repl-buf
    (vterm-send-string str)
    (vterm-send-return)
    (unless async
      ;; wait for the inclusion to succeed (i.e., the prompt prints)
      (julia-snail--wait-while (not (string-equal "julia>" (current-word))) 20 julia-snail-async-timeout))))

(cl-defun julia-snail--send-to-server
    (module
     str
     &key
     (repl-buf (get-buffer julia-snail-repl-buffer))
     (async t)
     (async-poll-interval 20)
     (async-poll-maximum julia-snail-async-timeout)
     (display-error-buffer-on-failure? t)
     callback-success
     callback-failure)
  "Send str to Snail server, and evaluate it in the context of
module. Run callback-success and callback-failure as appropriate.
When :async is t (default), return the request id. When :async is
nil, wait for the result and return it."
  (declare (indent defun))
  (unless repl-buf
    (user-error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer))
  (let* ((process-buf (get-buffer (julia-snail--process-buffer-name repl-buf)))
         (module-ns (julia-snail--construct-module-path module))
         (reqid (format "%04x%04x" (random (expt 16 4)) (random (expt 16 4))))
         (msg (format "(ns = %s, reqid = \"%s\", code = %s)\n"
                      module-ns
                      reqid
                      (json-encode-string str)))
         (res nil))
    (with-current-buffer process-buf
      (goto-char (point-max))
      (insert msg))
    (process-send-string process-buf msg)
    (spinner-start 'progress-bar)
    (puthash reqid
             (make-julia-snail--request-tracker
              :repl-buf repl-buf
              :originating-buf (current-buffer)
              :display-error-buffer-on-failure? display-error-buffer-on-failure?
              :callback-success (lambda (&optional data)
                                  (unless async
                                    (setq res (or data :nothing)))
                                  (when callback-success
                                    (funcall callback-success data)))
              :callback-failure (lambda ()
                                  (unless async
                                    (setq res :nothing))
                                  (when callback-failure
                                    (funcall callback-failure))))
             julia-snail--requests)
    (if async
        reqid
      (julia-snail--wait-while (null res) async-poll-interval async-poll-maximum)
      res)))

(cl-defun julia-snail--send-to-server-via-tmp-file
    (module
     str
     &key
     (repl-buf (get-buffer julia-snail-repl-buffer))
     callback-success
     callback-failure)
  "Send str to server by first writing it to a tmpfile, calling
Julia include on the tmpfile, and then deleting the file."
  (declare (indent defun))
  (let ((text (s-trim str))
        (tmpfile (make-temp-file
                  (expand-file-name "julia-tmp"
                                    (or small-temporary-file-directory
                                        temporary-file-directory)))))
    (progn
      (with-temp-file tmpfile
        (insert text))
      (let ((reqid (julia-snail--send-to-server
                     module
                     (format "include(\"%s\");" tmpfile)
                     :repl-buf repl-buf
                     ;; TODO: Only async via-tmp-file evaluation is currently
                     ;; supported because we rely on getting the reqid back from
                     ;; julia-snail--send-to-server, and that only happens with
                     ;; (async t). This may or may not be worth fixing in the
                     ;; future.
                     :async t
                     :callback-success callback-success
                     :callback-failure callback-failure)))
        (puthash reqid
                 (make-julia-snail--request-tracker
                  :repl-buf repl-buf
                  :originating-buf (current-buffer)
                  :callback-success callback-success
                  :callback-failure callback-failure
                  :tmpfile tmpfile)
                 julia-snail--requests)
        reqid))))

(defun julia-snail--server-response-filter (proc str)
  "Snail process filter for PROC given input STR; used as argument to `set-process-filter'."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      ;; insert at the end unconditionally
      (goto-char (point-max))
      (insert str)
      (set-marker (process-mark proc) (point))
      ;; Need to read and eval the value sent in by the process (str). But it
      ;; may have been chunked. Assume that a successful read signals the end of
      ;; input, but a failed read needs to be concatenated to other upcoming
      ;; reads. Track them in a table hashed by the proc.
      (let ((candidate (s-concat (gethash proc julia-snail--proc-responses) str)))
        (condition-case nil
            (let ((read-str (read candidate)))
              ;; read succeeds, so clean up and return its eval value
              (remhash proc julia-snail--proc-responses)
              ;; scary
              (eval read-str))
          ;; read failed: this means more data is incoming
          (end-of-file
           (puthash proc candidate julia-snail--proc-responses)))))))


 ;;; --- Snail server response handling functions

(defun julia-snail--response-base (reqid)
  "Snail response handler for REQID, base function."
  (let ((request-info (gethash reqid julia-snail--requests)))
    (when request-info
      ;; tmpfile
      (when-let (tmpfile (julia-snail--request-tracker-tmpfile request-info))
        (delete-file tmpfile))
      ;; stop spinner
      (with-current-buffer (julia-snail--request-tracker-originating-buf request-info)
        (spinner-stop))
      ;; remove request ID from requests hash
      (remhash reqid julia-snail--requests))))

(defun julia-snail--response-success (reqid result-data)
  "Snail success response handler for REQID given RESULT-DATA."
  (let* ((request-info (gethash reqid julia-snail--requests))
         (callback-success (julia-snail--request-tracker-callback-success request-info)))
    (when callback-success
      (funcall callback-success result-data)))
  (julia-snail--response-base reqid))

(defun julia-snail--response-failure (reqid error-message error-stack)
  "Snail failure response handler for REQID, display ERROR-MESSAGE and ERROR-STACK."
  (if (not julia-snail-show-error-window)
      (message error-message)
    (let* ((request-info (gethash reqid julia-snail--requests))
           (repl-buf (julia-snail--request-tracker-repl-buf request-info))
           (error-buffer (julia-snail--message-buffer
                          repl-buf
                          "error"
                          (format "%s\n\n%s" error-message (s-join "\n" error-stack))))
           (callback-failure (julia-snail--request-tracker-callback-failure request-info)))
      (when (julia-snail--request-tracker-display-error-buffer-on-failure? request-info)
        (pop-to-buffer error-buffer))
      (when callback-failure
        (funcall callback-failure))))
  (julia-snail--response-base reqid))


;;; --- xref implementation

(defun julia-snail-xref-backend ()
  "Emacs xref API."
  'xref-julia-snail)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql xref-julia-snail)))
  "Emacs xref API."
  (julia-snail--identifier-at-point))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql xref-julia-snail)))
  "Emacs xref API."
  (let* ((module (julia-snail-parser-query (current-buffer) (point) :module))
         (ns (s-join "." module)))
    (julia-snail--send-to-server
      module
      (format "Main.JuliaSnail.lsnames(%s, all=true, imported=true, include_modules=false, recursive=true)" ns)
      :async nil)))

(defun julia-snail--make-xrefs-helper (response)
  "Emacs xref API helper for RESPONSE."
  (if (or (null response) (eq :nothing response))
      nil
    (mapcar (lambda (candidate)
              (let ((descr (-first-item candidate))
                    (path (-second-item candidate))
                    (line (-third-item candidate)))
                (xref-make descr
                           (if (file-exists-p path)
                               (xref-make-file-location path line 0)
                             (xref-make-bogus-location
                              "xref not supported for definitions evaluated with julia-snail-send-top-level-form")))))
            response)))

(cl-defmethod xref-backend-definitions ((_backend (eql xref-julia-snail)) identifier)
  "Emacs xref API."
  (unless identifier
    (user-error "No identifier at point"))
  (let* ((module (julia-snail-parser-query (current-buffer) (point) :module))
         ;; Grab everything in the identifier up to the last dot, i.e., the
         ;; fully-qualified module name, and everything after the last dot,
         ;; which should be the symbol in the module.
         (identifier-split (save-match-data
                             (if (string-match
                                  "\\(.*\\)\\.\\(.*\\)"
                                  identifier)
                                 (list (match-string 1 identifier)
                                       (match-string 2 identifier))
                               (list module identifier))))
         (identifier-ns (-first-item identifier-split))
         (identifier-ns-real (if (listp identifier-ns)
                                 (-last-item identifier-ns)
                               identifier-ns))
         (identifier-name (-second-item identifier-split))
         (res (julia-snail--send-to-server
                module
                (format "Main.JuliaSnail.lsdefinitions(%s, \"%s\")"
                        identifier-ns-real identifier-name)
                :async nil)))
    (julia-snail--make-xrefs-helper res)))

;;; TODO: Implement this. See
;;; https://discourse.julialang.org/t/finding-uses-of-a-method/32729/3 for
;;; information about how it can be done. Key points: (1) It is most reliable
;;; for executed code, which is of course a non-starter for IDE functionality.
;;; (2) It can be done by iterating through all methods in all modules and
;;; calling Base.uncompressed_ast and looking for appropriate calls. Seems like
;;; it won't be accurate for functions called through indirection, but would
;;; definitely be a step in the right direction.
(cl-defmethod xref-backend-references ((_backend (eql xref-julia-snail)) _identifier)
  nil)

(cl-defmethod xref-backend-apropos ((_backend (eql xref-julia-snail)) pattern)
  (let* ((module (julia-snail-parser-query (current-buffer) (point) :module))
         (res (julia-snail--send-to-server
                module
                (format "Main.JuliaSnail.apropos(%s, \"%s\")"
                        (s-join "." module)
                        pattern)
                :async nil)))
    (julia-snail--make-xrefs-helper res)))


;;; --- completion implementation

(defun julia-snail--completions-keywords ()
  "Julia completion keywords."
  (list "abstract type" "begin" "catch" "do" "else" "elseif" "end"
        "false" "finally" "for" "function" "if" "let" "macro" "module"
        "mutable struct" "nothing" "primitive type" "quote" "struct"
        "true" "try" "undef" "while"))

(defun julia-snail--completions-base ()
  "Julia completion Base module names."
  (let ((process-buf (get-buffer (julia-snail--process-buffer-name julia-snail-repl-buffer))))
    ;; return (cached) list of Base names
    (if-let ((cached-base (gethash process-buf julia-snail--cache-proc-names-base)))
        cached-base
      (puthash process-buf
               (julia-snail--send-to-server
                 (list "Main")
                 "Main.JuliaSnail.lsnames(Main.Base, all=true, imported=true, include_modules=true, recursive=true)"
                 :async nil)
               julia-snail--cache-proc-names-base))))

(defun julia-snail--completions-core ()
  "Julia completion Core module names."
  (let ((process-buf (get-buffer (julia-snail--process-buffer-name julia-snail-repl-buffer))))
    ;; return (cached) list of Core names
    (if-let ((cached-core (gethash process-buf julia-snail--cache-proc-names-core)))
        cached-core
      (puthash process-buf
               (julia-snail--send-to-server
                 (list "Main")
                 "Main.JuliaSnail.lsnames(Main.Core, all=true, imported=true, include_modules=true, recursive=false)"
                 :async nil)
               julia-snail--cache-proc-names-core))))

(defun julia-snail--completions (identifier)
  "Completions helper for IDENTIFIER."
  (let* ((module (julia-snail-parser-query (current-buffer) (point) :module))
         (ns (-last-item module)))
    (append
     (julia-snail--completions-keywords)
     (julia-snail--completions-base)
     (julia-snail--completions-core)
     ;; handle a variable referencing a module
     (when (and identifier (s-ends-with? "." identifier))
       (let ((dotless (replace-regexp-in-string (rx "." string-end) "" identifier)))
         (mapcar
          (lambda (c) (s-prepend identifier c))
          (let ((res (julia-snail--send-to-server
                       module
                       (format "Main.JuliaSnail.lsnames(%s, all=false, imported=false, include_modules=false, recursive=false)" dotless)
                       :display-error-buffer-on-failure? nil
                       :async nil)))
            (if (eq :nothing res)
                (list)
              res)))))
     ;; the main list of names
     (julia-snail--send-to-server
       module
       (format "Main.JuliaSnail.lsnames(%s, all=true, imported=true, include_modules=true, recursive=true)" ns)
       :async nil))))

(defun julia-snail-completion-at-point ()
  "Implementation for Emacs `completion-at-point' system."
  (let ((identifier (julia-snail--identifier-at-point))
        (bounds (julia-snail--identifier-at-point-bounds)))
    (when bounds
      (list (car bounds)
            (cdr bounds)
            (completion-table-dynamic
             (lambda (_) (julia-snail--completions identifier)))
            :exclusive 'yes))))


;;; --- eldoc implementation

(defun julia-snail-eldoc ()
  "Implementation for ElDoc."
  ;; TODO: Implement something reasonable. This is pretty tricky to do in a
  ;; world of generic functions, since the parser will need to do the work of
  ;; figuring out just which possible signatures of a function are being called
  ;; and display documentation accordingly.
  nil
)


;;; --- commands

;;;###autoload
(defun julia-snail ()
  "Start a Julia REPL and connect to it, or switch if one already exists.
The following buffer-local variables control it:
- `julia-snail-repl-buffer' (default: *julia*)
- `julia-snail-port' (default: 10011)
To create multiple REPLs, give these variables distinct values (e.g.:
*julia my-project-1* and 10012)."
  (interactive)
  (let ((source-buf (current-buffer))
        (repl-buf (get-buffer julia-snail-repl-buffer)))
    (if repl-buf
        (progn
          (setf (buffer-local-value 'julia-snail--repl-go-back-target repl-buf) source-buf)
          (pop-to-buffer repl-buf))
      ;; run Julia in a vterm and load the Snail server file
      (let* ((vterm-shell (format "%s -L %s" julia-snail-executable julia-snail--server-file))
             (vterm-buffer (generate-new-buffer julia-snail-repl-buffer)))
        (with-current-buffer vterm-buffer
          (vterm-mode)
          (julia-snail-repl-mode))
        (pop-to-buffer vterm-buffer)
        (setq-local julia-snail-port (buffer-local-value 'julia-snail-port source-buf))
        (setq-local julia-snail--repl-go-back-target source-buf)))))

(defun julia-snail-send-line ()
  "Copy the line at the current point into the REPL and run it.
This is not module-context aware."
  (interactive)
  (let ((line (s-trim (thing-at-point 'line t))))
    (julia-snail--send-to-repl line)))

(defun julia-snail-send-buffer-file ()
  "Send the current buffer's file into the Julia REPL, and include() it.
This will occur in the context of the Main module, just as it would at the REPL."
  (interactive)
  (let ((filename buffer-file-name))
    (julia-snail--send-to-server
      :Main
      (format "include(\"%s\");" filename)
      :callback-success (lambda (&optional _data)
                          (message "%s loaded" filename)))))

(defun julia-snail-send-region ()
  "Send the region (requires transient-mark) to the Julia REPL and evaluate it.
This occurs in the context of the current module."
  (interactive)
  (if (null (use-region-p))
      (user-error "No region selected")
    (let ((text (buffer-substring-no-properties (region-beginning) (region-end)))
          (module (julia-snail-parser-query (current-buffer) (point) :module)))
      (julia-snail--send-to-server-via-tmp-file
        module text
        :callback-success (lambda (&optional data)
                            (message "Selected region evaluated: module %s, result: %s"
                                     (julia-snail--construct-module-path module)
                                     data))))))

(defun julia-snail-send-top-level-form ()
  "Send the top level form around the point to the Julia REPL and evaluate it.
This occurs in the context of the current module.
Currently only works on blocks terminated with `end'."
  (interactive)
  (let* ((q (julia-snail-parser-query (current-buffer) (point) :top-level-block))
         (module (plist-get q :module))
         (block-description (plist-get q :block))
         (block-start (-second-item block-description))
         (block-end (-third-item block-description))
         (text (buffer-substring-no-properties block-start block-end)))
    (julia-snail--flash-region block-start block-end 0.5)
    (julia-snail--send-to-server-via-tmp-file
      module text
      :callback-success (lambda (&optional _data)
                          (message "Top-level form evaluated: module %s, %s"
                                   (julia-snail--construct-module-path module)
                                   (if (-fourth-item block-description)
                                       (-fourth-item block-description)
                                     "unknown"))))))

(defun julia-snail-package-activate (dir)
  "Activate a Pkg project located in DIR in the Julia REPL."
  (interactive "DProject directory: ")
  (let ((expanded-dir (expand-file-name dir)))
    (julia-snail--send-to-server
      :Main
      (format "Pkg.activate(\"%s\")" expanded-dir)
      :callback-success (lambda (&optional _data)
                          (message "Package activated: %s" expanded-dir)))))

(defun julia-snail-doc-lookup (identifier)
  "Look up Julia documentation for symbol at point (IDENTIFIER)."
  (interactive (list (read-string
                      "Documentation look up: "
                      (unless current-prefix-arg (julia-snail--identifier-at-point)))))
  (let* ((module (julia-snail-parser-query (current-buffer) (point) :module))
         (name (s-concat (s-join "." module) "." identifier))
         (doc (julia-snail--send-to-server
                '("Main")
                (format "@doc %s" name)
                :display-error-buffer-on-failure? nil
                :async nil)))
    (pop-to-buffer (julia-snail--message-buffer
                    julia-snail-repl-buffer
                    (format "documentation: %s" identifier)
                    (if (eq :nothing doc)
                        "Documentation not found!\nDouble-check your package activation and imports."
                      doc)))))

(defun julia-snail-repl-go-back ()
  "Return to a source buffer from a Julia REPL buffer."
  (interactive)
  (when (boundp 'julia-snail--repl-go-back-target)
    (pop-to-buffer julia-snail--repl-go-back-target)))


;;; --- keymaps

(defvar julia-snail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'julia-snail)
    (define-key map (kbd "C-c C-a") #'julia-snail-package-activate)
    (define-key map (kbd "C-c C-d") #'julia-snail-doc-lookup)
    (define-key map (kbd "C-c C-c") #'julia-snail-send-top-level-form)
    (define-key map (kbd "C-M-x") #'julia-snail-send-top-level-form)
    (define-key map (kbd "C-c C-r") #'julia-snail-send-region)
    (define-key map (kbd "C-c C-l") #'julia-snail-send-line)
    (define-key map (kbd "C-c C-k") #'julia-snail-send-buffer-file)
    map))

(defvar julia-snail-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'julia-snail-repl-go-back)
    map))


;;; --- mode definitions

;;;###autoload
(define-minor-mode julia-snail-mode
  "A minor mode for interactive Julia development. Should only be turned on in source buffers."
  :init-value nil
  :lighter " Snail"
  :keymap julia-snail-mode-map
  (when (eq 'julia-mode major-mode)
    (if julia-snail-mode
        (progn
          (julia-snail--enable)
          (add-hook 'xref-backend-functions #'julia-snail-xref-backend nil t)
          (add-function :before-until (local 'eldoc-documentation-function) #'julia-snail-eldoc)
          (add-hook 'completion-at-point-functions #'julia-snail-completion-at-point nil t))
      (remove-hook 'completion-at-point-functions #'julia-snail-completion-at-point t)
      (remove-function (local 'eldoc-documentation-function) #'julia-snail-eldoc)
      (remove-hook 'xref-backend-functions #'julia-snail-xref-backend t)
      (julia-snail--disable))))

;;;###autoload
(define-minor-mode julia-snail-repl-mode
  "A minor mode for interactive Julia development. Should only be
turned on in REPL buffers."
  :init-value nil
  :lighter " Snail"
  :keymap julia-snail-repl-mode-map
  (when (eq 'vterm-mode major-mode)
    (if julia-snail-repl-mode
        (julia-snail--repl-enable)
      (julia-snail--repl-disable))))

(define-minor-mode julia-snail-message-buffer-mode
  "A minor mode for displaying messages returned from the Julia REPL."
  :init-value nil
  :lighter " Snail Message"
  :keymap '(((kbd "q") . quit-window)))


;;; --- done

(provide 'julia-snail)

;;; julia-snail.el ends here
