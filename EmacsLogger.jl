#-------------------------------------------------------------------------------
# EmacsLogger

using .JuliaSnail
import Base.AbstractLogger,Base.LogLevel,Base.CoreLogging,Base64.base64encode

struct EmacsLogger <: AbstractLogger
    min_level::LogLevel
    message_limits::Dict{Any,Int}
end


EmacsLogger(level=Base.CoreLogging.Info) = EmacsLogger(level, Dict{Any,Int}())

CoreLogging.shouldlog(logger::EmacsLogger, level, _module, group, id) =
    get(logger.message_limits, id, 1) > 0

CoreLogging.min_enabled_level(logger::EmacsLogger) = logger.min_level
CoreLogging.catch_exceptions(logger::EmacsLogger) = false

function CoreLogging.handle_message(logger::EmacsLogger, level, message, _module, group, id,filepath, line; maxlog=nothing, kwargs...)
    if maxlog !== nothing && maxlog isa Integer
        remaining = get!(logger.message_limits, id, maxlog)
        logger.message_limits[id] = remaining - 1
        remaining > 0 || return
    end
#    levelstr = level == Warn ? "Warning" : string(level)
    el = JuliaSnail.elexpr((Symbol("julia-snail--log-message"),string(level),base64encode(message)))
    JuliaSnail.send_to_client(el)
    sleep(.02)
    nothing
end


