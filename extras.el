(defun julia-snail-kill-and-restart ()
  (interactive)
  (julia-snail--send-to-repl "exit()")
;  (vterm-)
  (kill-buffer julia-snail-repl-buffer)
  (julia-snail)
  )


(defun julia-snail--lookup-history ()
    (julia-snail--send-to-server
      :JuliaSnail
       "history()"
      :async nil))

(defun julia-snail-history-search ()
  (interactive)
  (let* ((res (completing-read "" (julia-snail--lookup-history))))
    (julia-snail--send-to-server
      :JuliaSnail
      (format "insert_history_result(\"%s\")" res)
      :async nil))
  )

(define-key julia-snail-repl-mode-map (kbd "C-c C-s") #'julia-snail-search-history-and-insert)


(defun get-create-log-buffer ()
  (progn 
  (if (not (get-buffer "*julia logs*"))
      (with-current-buffer (get-buffer-create "*julia logs*")
        (org-mode)
        (julia-snail-plot-mode)
        )
    )
  (get-buffer "*julia logs*"))
  )

(defun julia-snail--reset-history (idx)
    (julia-snail--send-to-server
      :Main
      (format "transition_to_index(hp,%i)" idx)
      :async nil))
  


(defun julia-snail--log-text (txt)
  (with-current-buffer (get-create-log-buffer)
    (goto-char (point-max))
    (insert txt)
    (julia-snail-plot-mode)
  ))

(defun julia-snail--log-clear ()
  (with-current-buffer (get-create-log-buffer)
    (erase-buffer)
    ))

(defun julia-snail--log-pop ()
  (pop-to-buffer "*julia logs*")
  )

(defun julia-snail--log-matrix (csv)
    (with-current-buffer (get-create-log-buffer)
      (goto-char (point-max))
      (let ((pp (point)))
        (insert csv)
        (org-table-convert-region pp (point-max))
        (goto-char (point-max))
        (insert "\n")
        )))



(defun julia-snail--log-image (im decode)
  (progn
    (if decode (setq im (base64-decode-string im)))

    (let ((buf (get-create-log-buffer)) (img (create-image im nil t)))
      (with-current-buffer buf
        (goto-char (point-max))
        (unless  (= (point-max) (point-min))
          (progn
            (insert (propertize "      \n" 'face 'underline))
            (insert "\n")
            ))
        (insert-image img "julia plot")
        (goto-char (point-max))
        (insert "\n")
        )
      ))
  )

