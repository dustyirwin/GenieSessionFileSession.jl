module GenieSessionFileSession

import Genie, GenieSession
import Serialization, Logging

# 🔑 Precompile-safe: literal initializer. Real value set in __init__.
const SESSIONS_PATH = Ref{String}("")

function sessions_path(path::String)
    SESSIONS_PATH[] = normpath(path) |> abspath
end

function sessions_path()
    p = SESSIONS_PATH[]
    if isempty(p)
        # Lazy fallback if __init__ didn't run or was skipped
        p = if Sys.iswindows()
            joinpath(get(ENV, "LOCALAPPDATA",
                         joinpath(homedir(), "AppData", "Local")),
                     "UCIAgg", "sessions")
        else
            joinpath(homedir(), ".local", "share", "UCIAgg", "sessions")
        end
        mkpath(p)
        SESSIONS_PATH[] = p
    end
    return p
end

function _runtime_session_folder()
    base = if Sys.iswindows()
        get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    else
        joinpath(homedir(), ".local", "share")
    end
    return joinpath(base, "UCIAgg", "sessions")
end

function setup_folder(folder::String)
    try
        mkpath(folder)
        SESSIONS_PATH[] = normpath(folder) |> abspath
    catch e
        fallback = _runtime_session_folder()
        @warn "GenieSessionFileSession: session folder $folder not writable ($(typeof(e))); using $fallback instead"
        try
            mkpath(fallback)
            SESSIONS_PATH[] = normpath(fallback) |> abspath
        catch e2
            @warn "GenieSessionFileSession: fallback $fallback also failed" exception=e2
        end
    end
end

function __init__()
    try
        # 🔑 Compute path at RUNTIME, not precompile time.
        # This is what `const` initialization used to do — now it lives here
        # so the path isn't baked into the sysimage.
        SESSIONS_PATH[] = Genie.Configuration.isprod() ? "sessions" : mktempdir()
        setup_folder(SESSIONS_PATH[])
    catch e
        @warn "GenieSessionFileSession.__init__ skipped due to: $e"
    end
end


"""
    write(session::GenieSession.Session) :: GenieSession.Session

Persists the `Session` object to the file system, using the configured sessions folder and returns it.
"""
function write(session::GenieSession.Session) :: GenieSession.Session
  try
    write_session(session)

    return session
  catch ex
    @error "Failed to store session data"
    @error ex
  end

  try
    @error "Resetting session"

    session = GenieSession.Session(GenieSession.id())
    Genie.Cookies.set!(Genie.Router.params(Genie.Router.PARAMS_RESPONSE_KEY), GenieSession.session_key_name(), session.id, GenieSession.session_options())
    write_session(session)
    Genie.Router.params(GenieSession.PARAMS_SESSION_KEY, session)

    return session
  catch ex
    @error "Failed to regenerate and store session data. Giving up."
    @error ex
  end

  session
end


function write_session(session::GenieSession.Session)
  isdir(sessions_path()) || mkpath(sessions_path())

  open(joinpath(sessions_path(), session.id), "w") do io
    Serialization.serialize(io, session)
  end
end


"""
    read(session_id::Union{String,Symbol}) :: Union{Nothing,GenieSession.Session}
    read(session::GenieSession.Session) :: Union{Nothing,GenieSession.Session}

Attempts to read from file the session object serialized as `session_id`.
"""
function read(session_id::String) :: Union{Nothing,GenieSession.Session}
  try
    isfile(joinpath(sessions_path(), session_id)) || return nothing
  catch ex
    @debug "Failed to read session data"
    @debug ex

    return nothing
  end

  try
    open(joinpath(sessions_path(), session_id), "r") do (io)
      Serialization.deserialize(io)
    end
  catch ex
    @debug "Can't read session"
    # @error ex
  end
end

function read(session::GenieSession.Session) :: Union{Nothing,GenieSession.Session}
  read(session.id)
end

#===#
# IMPLEMENTATION

"""
    persist(s::Session) :: Session

Generic method for persisting session data - delegates to the underlying `SessionAdapter`.
"""
function GenieSession.persist(req::GenieSession.HTTP.Request, res::GenieSession.HTTP.Response, params::Dict{Symbol,Any}) :: Tuple{GenieSession.HTTP.Request,GenieSession.HTTP.Response,Dict{Symbol,Any}}
  write(params[GenieSession.PARAMS_SESSION_KEY])

  req, res, params
end
function GenieSession.persist(s::GenieSession.Session) :: GenieSession.Session
  write(s)
end


"""
    load(session_id::String) :: Session

Loads session data from persistent storage.
"""
function GenieSession.load(session_id::String) :: GenieSession.Session
  session = read(session_id)

  session === nothing ? GenieSession.Session(session_id) : (session)
end

end