{- |
Module      : Web.Api.Http.Types
Description : Auxilliary types for the `HttpSession` monad.
Copyright   : 2018, Automattic, Inc.
License     : GPL-3
Maintainer  : Nathan Bloomfield (nbloomf@gmail.com)
Stability   : experimental
Portability : POSIX

`HttpSession` is a stack of monads dealing with errors, state, environment, and logs. This module defines the auxiliary types used to represent this information.
-}

{-# LANGUAGE RecordWildCards #-}
module Web.Api.Http.Types (
  -- * Errors
    Err(..)
  , printErr

  -- * Logs
  , Log(..)
  , Entry(..)
  , HttpVerb(..)
  , SessionVerb(..)

  -- * State
  , St()
  , theTcpSession
  , setTcpSession
  , theLastResponse
  , setLastResponse
  , theClientState
  , setClientState
  , updateClientState
  , basicState

  -- * Environment
  , Env()
  , theLogPrinter
  , setLogPrinter
  , theLogVerbosity
  , setLogVerbosity
  , theLogHandle
  , setLogHandle
  , theAssertionLogHandle
  , setAssertionLogHandle
  , theConsoleInHandle
  , setConsoleInHandle
  , theConsoleOutHandle
  , setConsoleOutHandle
  , theErrorInjectFunction
  , setErrorInjectFunction
  , theClientEnvironment
  , setClientEnvironment
  , theLogLock
  , setLogLock
  , theSessionUid
  , setSessionUid
  , basicEnv
  , jsonEnv

  -- * Configuration
  , HttpSessionConfig(..)
  , basicHttpSessionConfig
  , jsonHttpSessionConfig
  , setEnvironment
  , setState

  -- * Pretty Printing
  , LogPrinter(..)
  , printEntryWith
  , basicLogPrinter
  , jsonLogPrinter
  , LogVerbosity()
  , noisyLog
  , silentLog
  ) where

import Data.Aeson
  ( Value, decode )
import Control.Exception
  ( IOException )
import Data.Aeson.Lens
  ( _Value )
import Data.Aeson.Encode.Pretty
  ( encodePretty )
import Control.Lens hiding
  ( (.=) )
import Data.ByteString.Lazy.Char8
  ( unpack, pack )
import qualified Network.Wreq as Wreq
  ( Options, responseStatus )
import qualified Network.Wreq.Session as WreqS
  ( Session )
import Data.ByteString.Lazy
  ( ByteString, fromStrict )
import Data.Time
  ( UTCTime )
import Network.HTTP.Client
  ( HttpException(HttpExceptionRequest)
  , HttpExceptionContent(StatusCodeException) )
import System.IO
  ( Handle, stderr, stdout, stdin )
import System.IO.Error
  ( ioeGetFileName, ioeGetLocation, ioeGetErrorString )
import Control.Concurrent.MVar
  ( MVar )


import Web.Api.Http.Assert
import Web.Api.Http.Effects
import Web.Api.Http.Json



-- | Errors we expect to encounter during an HTTP interaction.

data Err err
  -- | HTTP Exceptions, like network errors and non-ok status responses.
  = ErrHttp HttpException

  -- | IO exceptions, like "disk full" errors.
  | ErrIO IOException

  -- | JSON parsing or decoding errors.
  | ErrJson JsonError

  -- | Expected failure, and success is catastrophic.
  | ErrUnexpectedSuccess String

  -- | For catastrophic failed assertions.
  | ErrUnexpectedFailure String

  -- | Unspecified error; defined by consumers of `HttpSession`.
  | Err err
  deriving Show


-- | For pretty printing.
printErr :: (err -> String) -> Err err -> String
printErr p e = case e of
  ErrHttp err -> show err
  ErrIO err -> show err
  ErrJson err -> show err
  ErrUnexpectedSuccess msg -> msg
  ErrUnexpectedFailure msg -> msg
  Err err -> p err



-- | The events we expect to log during an HTTP interaction. The `Log` type is really two logs rolled into one: there's the "session log", where we keep track of requests and responses and explicitly logged messages, and the "assertion log", where we keep track of `Assertion`s. Each log is just a list of timestamp/message pairs.

data Log err log = Log
  [(UTCTime, Entry err log)]
  [(UTCTime, Assertion)]

instance Monoid (Log err log) where
  mempty = Log [] []

  mappend (Log as1 bs1) (Log as2 bs2) =
    Log (as1 ++ as2) (bs1 ++ bs2)

-- | Default log entry constructors of different semantics. As with errors, each client may need to log other kinds of information, represented by the `log` type.

data Entry err log
  -- | Unspecified log entry type; defined by consumers of `HttpSession`.
  = LogItem log

  -- | Delays, measured in microseconds.
  | LogPause Int

  -- | Arbitrary text.
  | LogComment String

  -- | An assertion was made. This is independent of the assertion log.
  | LogAssertion Assertion

  -- | An HTTP request was made.
  | LogRequest HttpVerb Url Wreq.Options (Maybe ByteString)

  -- | An HTTP request was made, but the details are omitted. Useful for keeping secrets out of the logs.
  | LogSilentRequest

  -- | An HTTP response was received.
  | LogResponse HttpResponse

  -- | An HTTP response was received, but the details are omitted. Useful for keeping secrets out of the logs.
  | LogSilentResponse

  -- | A `Session` (in the @wreq@ sense) was opened or closed.
  | LogSession SessionVerb

  -- | An HTTP error was thrown.
  | LogHttpError HttpException

  -- | An IO error was thrown.
  | LogIOError IOException

  -- | A JSON error was thrown.
  | LogJsonError JsonError

  -- | Unexpected success.
  | LogUnexpectedSuccess String

  -- | Unexpected failure.
  | LogUnexpectedFailure String

  -- | An unspecified error of type defined by consumers of `HttpSession` was thrown.
  | LogError err
  deriving Show

-- | Representation of the HTTP request types.
data HttpVerb
  = DELETE | GET | POST
  deriving (Eq, Show)

-- | Representation of the actions we can perform on a `Session` (in the @wreq@ sense).
data SessionVerb
  = Close | Open
  deriving (Eq, Show)



-- | An opaque type representing the state we expect to keep during an HTTP interaction.

data St st = St {
  -- | If not `Nothing`, this allows the `HttpSession` to reuse TCP connections and remember cookies.
    __http_session :: Maybe WreqS.Session

  -- | The "most recent" non-error HTTP response.
  , __last_response :: Maybe HttpResponse

  -- | Specified by consumers of `HttpSession`.
  , __user_state :: st
  }

-- | Retrieve the TCP session in a monadic context.
theTcpSession
  :: (Monad m) => St st -> m (Maybe WreqS.Session)
theTcpSession = return . __http_session

-- | Set the TCP session of an `St`.
setTcpSession
  :: Maybe WreqS.Session -> St st -> St st
setTcpSession s st = st { __http_session = s }

-- | Retrieve the most recent HTTP response in a monadic context.
theLastResponse
  :: (Monad m) => St st -> m (Maybe HttpResponse)
theLastResponse = return . __last_response

-- | Set the most recent HTTP response of an `St`.
setLastResponse
  :: Maybe HttpResponse -> St st -> St st
setLastResponse r st = st { __last_response = r }

-- | Retrieve the client state in a monadic context.
theClientState
  :: (Monad m) => St st -> m st
theClientState = return . __user_state

-- | Set the client state of an `St`.
setClientState
  :: st -> St st -> St st
setClientState s st = st { __user_state = s }

-- | Mutate the client state of an `St`.
updateClientState
  :: (st -> st) -> St st -> St st
updateClientState f st = st
  { __user_state = f $ __user_state st }

-- | For creating an "initial" state, with all other fields left as `Nothing`s.
basicState :: st -> St st
basicState st = St
  { __http_session = Nothing
  , __last_response = Nothing
  , __user_state = st
  }




-- | An opaque type representing the read-only environment we expect to need during an `HttpSession`. This is for configuration-like state that doesn't change over the course of a single session, like the location of the log file.

data Env err log env = Env {
  -- | Used for making the appearance of logs configurable.
    __log_printer :: LogPrinter err log

  -- | Used to control the verbosity of the logs.
  , __log_verbosity :: LogVerbosity err log

  -- | The handle of the session log file.
  , __log_handle :: Handle

  -- | The handle of the assertion log file.
  , __assertion_log_handle :: Handle

  -- | The handle of console input.
  , __console_in_handle :: Handle

  -- | The handle of console output.
  , __console_out_handle :: Handle

  -- | A function used to inject `HttpException`s into the consumer-supplied error type. Handy when dealing with APIs that use HTTP error codes semantically.
  , __http_error_inject :: Maybe (HttpException -> Maybe err)

  , __log_lock :: Maybe (MVar ())

  , __session_uid :: String

  -- | Unspecified environment type; defined by consumers of `HttpSession`.
  , __user_env :: env
  }

-- | Retrieve the `LogPrinter` in a monadic context.
theLogPrinter
  :: (Monad m) => Env err log env -> m (LogPrinter err log)
theLogPrinter = return . __log_printer

-- | Set the `LogPrinter` of an `Env`.
setLogPrinter
  :: LogPrinter err log -> Env err log env -> Env err log env
setLogPrinter printer env = env { __log_printer = printer }

-- | Retrieve the `LogVerbosity` in a monadic context.
theLogVerbosity
  :: (Monad m) => Env err log env -> m (LogVerbosity err log)
theLogVerbosity = return . __log_verbosity

-- | Set the `LogVerbosity` of an `Env`.
setLogVerbosity
  :: LogVerbosity err log -> Env err log env -> Env err log env
setLogVerbosity verbosity env = env { __log_verbosity = verbosity }

-- | Retrieve the log handle in a monadic context.
theLogHandle
  :: (Monad m) => Env err log env -> m Handle
theLogHandle = return . __log_handle

-- | Set the log handle of an `Env`.
setLogHandle
  :: Handle -> Env err log env -> Env err log env
setLogHandle handle env = env { __log_handle = handle }

-- | Retrieve the assertion log handle in a monadic context.
theAssertionLogHandle
  :: (Monad m) => Env err log env -> m Handle
theAssertionLogHandle = return . __assertion_log_handle

-- | Set the assertion log handle of an `Env`.
setAssertionLogHandle
  :: Handle -> Env err log env -> Env err log env
setAssertionLogHandle handle env = env { __assertion_log_handle = handle }

-- | Retrieve the log handle in a monadic context.
theConsoleInHandle
  :: (Monad m) => Env err log env -> m Handle
theConsoleInHandle = return . __console_in_handle

-- | Set the log handle of an `Env`.
setConsoleInHandle
  :: Handle -> Env err log env -> Env err log env
setConsoleInHandle handle env = env { __console_in_handle = handle }

-- | Retrieve the log handle in a monadic context.
theConsoleOutHandle
  :: (Monad m) => Env err log env -> m Handle
theConsoleOutHandle = return . __console_out_handle

-- | Set the log handle of an `Env`.
setConsoleOutHandle
  :: Handle -> Env err log env -> Env err log env
setConsoleOutHandle handle env = env { __console_out_handle = handle }

-- | Retrieve the HTTP exception injecting function in a monadic context.
theErrorInjectFunction
  :: (Monad m) => Env err log env -> m (Maybe (HttpException -> Maybe err))
theErrorInjectFunction = return . __http_error_inject

-- | Set the HTTP exception injecting function of an `Env`.
setErrorInjectFunction
  :: Maybe (HttpException -> Maybe err) -> Env err log env -> Env err log env
setErrorInjectFunction func env = env { __http_error_inject = func }

-- | Retrieve the client environment in a monadic context.
theClientEnvironment
  :: (Monad m) => Env err log env -> m env
theClientEnvironment = return . __user_env

-- | Set the client environment of an `Env`.
setClientEnvironment
  :: env -> Env err log env -> Env err log env
setClientEnvironment e env = env { __user_env = e }

-- | Retrieve the log lock in a monadic context.
theLogLock
  :: (Monad m) => Env err log env -> m (Maybe (MVar ()))
theLogLock = return . __log_lock

-- | Set the log lock of an `Env`.
setLogLock
  :: Maybe (MVar ()) -> Env err log env -> Env err log env
setLogLock logLock env = env { __log_lock = logLock }

-- | Retrieve the log lock in a monadic context.
theSessionUid
  :: (Monad m) => Env err log env -> m String
theSessionUid = return . __session_uid

-- | Set the log lock of an `Env`.
setSessionUid
  :: String -> Env err log env -> Env err log env
setSessionUid sessionUid env = env { __session_uid = sessionUid }


-- | A reasonable standard environment for text or binary oriented APIs: logs are printed with `basicLogPrinter`, the session log goes to `stderr`, and the assertion log goes to `stdout`.
basicEnv
  :: (err -> String)                    -- ^ Function for printing consumer-defined errors.
  -> (log -> String)                    -- ^ Function for printing consumer-defined logs.
  -> Maybe (HttpException -> Maybe err) -- ^ Function for injecting HTTP exceptions as consumer-defined errors.
  -> env
  -> Env err log env
basicEnv printErr printLog promote env = Env
  { __log_printer = basicLogPrinter True printErr printLog showAssertion
  , __log_verbosity = noisyLog
  , __log_handle = stderr
  , __assertion_log_handle = stdout
  , __console_in_handle = stdin
  , __console_out_handle = stdout
  , __http_error_inject = promote
  , __log_lock = Nothing
  , __session_uid = ""
  , __user_env = env
  }

-- | A reasonable standard environment for JSON oriented APIs: logs are printed with `jsonLogPrinter`, the session log goes to `stderr`, and the assertion log goes to `stdout`.
jsonEnv
  :: (err -> String)                    -- ^ Function for printing consumer-defined errors.
  -> (log -> String)                    -- ^ Function for printing consumer-defined logs.
  -> Maybe (HttpException -> Maybe err) -- ^ Function for injecting HTTP exceptions as consumer-defined errors.
  -> env
  -> Env err log env
jsonEnv printErr printLog promote env = Env
  { __log_printer = jsonLogPrinter True printErr printLog showAssertion
  , __log_verbosity = noisyLog
  , __log_handle = stderr
  , __assertion_log_handle = stdout
  , __console_in_handle = stdin
  , __console_out_handle = stdout
  , __http_error_inject = promote
  , __log_lock = Nothing
  , __session_uid = ""
  , __user_env = env
  }




-- | Each HTTP session needs an initial state and an environment to run in; we wrap this data in a helper type called `HttpSessionConfig` for convenience. Doing this -- rather than passing all this into `runSession` directly -- makes session context explicitly first class, and also gives us more flexibility to add new default context in the future if needed.

data HttpSessionConfig err st log env = HttpSessionConfig
  { __initial_state :: St st
  , __environment :: Env err log env
  }

-- We also give a couple of built in configurations. One assumes that all HTTP payloads are formatted as JSON (a reasonable and commonly valid assumption) and the other does not. Clients don't have to deviate from these unless they really want to.

-- | A reasonable standard configuration for text or binary oriented APIs. Uses `basicState` and `basicEnv` internally.
basicHttpSessionConfig
  :: (err -> String)                    -- ^ Function for printing consumer-defined errors.
  -> (log -> String)                    -- ^ Function for printing consumer-defined logs.
  -> Maybe (HttpException -> Maybe err) -- ^ Function for injecting HTTP exceptions as consumer-defined errors.
  -> st
  -> env
  -> HttpSessionConfig err st log env
basicHttpSessionConfig printErr printLog promote st env =
  HttpSessionConfig
    { __initial_state = basicState st
    , __environment = basicEnv printErr printLog promote env
    }

-- | A reasonable standard configuration for JSON oriented APIs. Uses `basicState` and `jsonEnv` internally.
jsonHttpSessionConfig
  :: (err -> String)                    -- ^ Function for printing consumer-defined errors.
  -> (log -> String)                    -- ^ Function for printing consumer-defined logs.
  -> Maybe (HttpException -> Maybe err) -- ^ Function for injecting HTTP exceptions as consumer-defined errors.
  -> st
  -> env
  -> HttpSessionConfig err st log env
jsonHttpSessionConfig printErr printLog promote st env =
  HttpSessionConfig
    { __initial_state = basicState st
    , __environment = jsonEnv printErr printLog promote env
    }

-- | Mutate the environment data of an `HttpSessionConfig`.
setEnvironment
  :: (Env err log env -> Env err log env)
  -> HttpSessionConfig err st log env
  -> HttpSessionConfig err st log env
setEnvironment f config = config
  { __environment = f $ __environment config }

-- | Mutate the initial state of an `HttpSessionConfig`.
setState
  :: (St st -> St st)
  -> HttpSessionConfig err st log env
  -> HttpSessionConfig err st log env
setState f config = config
  { __initial_state = f $ __initial_state config }


-- | A type representing the functions used to print logs. With this type, and the `basicLogPrinter` and `jsonLogPrinter` values, consumers of `HttpSession` don't have to think about formatting their logs beyond their specific `log` and `err` types unless they *really* want to.
data LogPrinter err log = LogPrinter {
  -- | Printer for consumer-defined errors.
    __error :: UTCTime -> String -> err -> String

  -- | Printer for comments.
  , __comment :: UTCTime -> String -> String -> String

  -- | Printer for detailed HTTP requests.
  , __request :: UTCTime -> String -> HttpVerb -> String -> Wreq.Options -> Maybe ByteString -> String

  -- | Printer for detailed HTTP responses.
  , __response :: UTCTime -> String -> HttpResponse -> String

  -- | Printer for `HttpException`s.
  , __http_error :: UTCTime -> String -> HttpException -> String

  -- | Printer for silent HTTP requests.
  , __silent_request :: UTCTime -> String -> String

  -- | Printer for slient HTTP responses.
  , __silent_response :: UTCTime -> String -> String

  -- | Printer for `IOException`s.
  , __io_error :: UTCTime -> String -> IOException -> String

  -- | Printer for session actions.
  , __session :: UTCTime -> String -> SessionVerb -> String

  -- | Printer for `JsonError`s.
  , __json_error :: UTCTime -> String -> JsonError -> String

  -- | Printer for `UnexpectedSuccess`.
  , __unexpected_success :: UTCTime -> String -> String -> String

  -- | Printer for `UnexpectedFailure`.
  , __unexpected_failure :: UTCTime -> String -> String -> String

  -- | Printer for `Assertion`s.
  , __assertion :: UTCTime -> String -> Assertion -> String

  -- | Printer for delay events.
  , __pause :: UTCTime -> String -> Int -> String

  -- | Printer for consumer-defined log entries.
  , __log :: UTCTime -> String -> log -> String
  }


-- | Type representing fine-grained log verbosity options.
data LogVerbosity err log = LogVerbosity
  { _err_verbosity :: err -> Bool
  , _comment_verbosity :: Bool
  , _request_verbosity :: Bool
  , _response_verbosity :: Bool
  , _http_error_verbosity :: Bool
  , _silent_request_verbosity :: Bool
  , _silent_response_verbosity :: Bool
  , _io_error_verbosity :: Bool
  , _json_error_verbosity :: Bool
  , _unexpected_success_verbosity :: Bool
  , _unexpected_failure_verbosity :: Bool
  , _session_verbosity :: Bool
  , _assertion_verbosity :: Bool
  , _pause_verbosity :: Bool
  , _log_verbosity :: log -> Bool
  }


-- | Prints all logs.
noisyLog :: LogVerbosity err log
noisyLog = LogVerbosity
  { _err_verbosity = const True
  , _comment_verbosity = True
  , _request_verbosity = True
  , _response_verbosity = True
  , _http_error_verbosity = True
  , _silent_request_verbosity = True
  , _silent_response_verbosity = True
  , _io_error_verbosity = True
  , _json_error_verbosity = True
  , _unexpected_success_verbosity = True
  , _unexpected_failure_verbosity = True
  , _session_verbosity = True
  , _assertion_verbosity = True
  , _pause_verbosity = True
  , _log_verbosity = const True
  }


-- | Suppresses all logs.
silentLog :: LogVerbosity err log
silentLog = LogVerbosity
  { _err_verbosity = const False
  , _comment_verbosity = False
  , _request_verbosity = False
  , _response_verbosity = False
  , _http_error_verbosity = False
  , _silent_request_verbosity = False
  , _silent_response_verbosity = False
  , _io_error_verbosity = False
  , _json_error_verbosity = False
  , _unexpected_success_verbosity = False
  , _unexpected_failure_verbosity = False
  , _session_verbosity = False
  , _assertion_verbosity = False
  , _pause_verbosity = False
  , _log_verbosity = const False
  }


-- | Prints a log entry with the given `LogPrinter`.
printEntryWith :: LogPrinter err log -> LogVerbosity err log -> (UTCTime, String, Entry err log) -> Maybe String
printEntryWith printer LogVerbosity{..} (time, uid, entry) = case entry of
  LogError err -> if _err_verbosity err
    then Just $ __error printer time uid err
    else Nothing
  LogComment msg -> if _comment_verbosity
    then Just $ __comment printer time uid msg
    else Nothing
  LogRequest verb url opts payload -> if _request_verbosity
    then Just $ __request printer time uid verb url opts payload
    else Nothing
  LogResponse str -> if _response_verbosity
    then Just $ __response printer time uid str
    else Nothing
  LogHttpError err -> if _http_error_verbosity
    then Just $ __http_error printer time uid err
    else Nothing
  LogSilentRequest -> if _silent_request_verbosity
    then Just $ __silent_request printer time uid
    else Nothing
  LogSilentResponse -> if _silent_response_verbosity
    then Just $ __silent_response printer time uid
    else Nothing
  LogIOError err -> if _io_error_verbosity
    then Just $ __io_error printer time uid err
    else Nothing
  LogJsonError err -> if _json_error_verbosity
    then Just $ __json_error printer time uid err
    else Nothing
  LogUnexpectedSuccess msg -> if _unexpected_success_verbosity
    then Just $ __unexpected_success printer time uid msg
    else Nothing
  LogUnexpectedFailure msg -> if _unexpected_failure_verbosity
    then Just $ __unexpected_failure printer time uid msg
    else Nothing
  LogSession verb -> if _session_verbosity
    then Just $ __session printer time uid verb
    else Nothing
  LogAssertion x -> if _assertion_verbosity
    then Just $ __assertion printer time uid x
    else Nothing
  LogPause m -> if _pause_verbosity
    then Just $ __pause printer time uid m
    else Nothing
  LogItem x -> if _log_verbosity x
    then Just $ __log printer time uid x
    else Nothing


-- Helpers for printing timestamps and coloring text.

trunc :: UTCTime -> String
trunc = take 19 . show

paint :: Bool -> (String -> String) -> String -> String
paint inColor f x = (if inColor then f else id) x

red str = "\x1b[1;31m" ++ str ++ "\x1b[0;39;49m"
blue str = "\x1b[1;34m" ++ str ++ "\x1b[0;39;49m"
green str = "\x1b[1;32m" ++ str ++ "\x1b[0;39;49m"
yellow str = "\x1b[1;33m" ++ str ++ "\x1b[0;39;49m"
magenta str = "\x1b[1;35m" ++ str ++ "\x1b[0;39;49m"


-- | A `LogPrinter` that treats all requests and responses as plain text.
basicLogPrinter
  :: Bool                   -- ^ If true, print in color
  -> (err -> String)        -- ^ Function for printing consumer-defined errors
  -> (log -> String)        -- ^ Function for printing consumer-defined logs
  -> (Assertion -> String)  -- ^ Function for printing `Assertion`s
  -> LogPrinter err log
basicLogPrinter color pE pL pA = LogPrinter
  { __error = \time uid err -> unwords
    [paint color red $ trunc time, uid, "ERROR", pE err]
  , __comment = \time uid msg -> unwords
    [paint color green $ trunc time, uid, msg]
  , __request = \time uid verb url opts payload -> unwords
    [paint color blue $ trunc time, uid, show verb, url]
  , __response = \time uid response -> unwords
    [paint color blue $ trunc time, uid, show response]
  , __http_error = \time uid err -> unwords
    [paint color red $ trunc time, uid, show err]
  , __silent_request = \time uid -> unwords
    [paint color blue $ trunc time, uid, "Silent Request"]
  , __silent_response = \time uid -> unwords
    [paint color blue $ trunc time, uid, "Silent Response"]
  , __io_error = \time uid err -> unwords
    [ paint color red $ trunc time, uid
    , show $ ioeGetFileName err
    , ioeGetLocation err
    , ioeGetErrorString err
    ]
  , __json_error = \time uid err -> unwords
    [paint color red $ trunc time, uid, show err]
  , __unexpected_success = \time uid msg -> unwords
    [paint color red $ trunc time, uid, "Unexpected Success: ", msg]
  , __unexpected_failure = \time uid msg -> unwords
    [paint color red $ trunc time, uid, "Unexpected Failure: ", msg]
  , __session = \time uid verb -> unwords
    [paint color magenta $ trunc time, uid, show verb]
  , __assertion = \time uid a -> unwords
    [paint color magenta $ trunc time, uid, pA a]
  , __pause = \time uid m -> unwords
    [paint color magenta $ trunc time, uid, "pause for", show m ++ "μs"]
  , __log = \time uid x -> unwords
    [paint color yellow $ trunc time, uid, pL x]
  }

-- | `LogPrinter` that treats all requests and responses as JSON objects.
jsonLogPrinter
  :: Bool                  -- ^ If true, print in color
  -> (err -> String)       -- ^ Function for printing consumer-defined errors
  -> (log -> String)       -- ^ Function for printing consumer-defined logs
  -> (Assertion -> String) -- ^ Function for printing `Assertion`s
  -> LogPrinter err log
jsonLogPrinter color pE pL pA = (basicLogPrinter color pE pL pA)
  { __request = \time uid verb url opts payload ->
      let
        json = case payload of
          Nothing -> ""
          Just x -> case decode x of
            Nothing -> "parse error:\n" ++ unpack x
            Just v -> ('\n':) $ unpack $ encodePretty (v :: Value)
      in
        unwords [paint color blue $ trunc time, uid, show verb, url]
          ++ json
  , __response = \time uid response ->
      let
        headers = __response_headers response
        json = unpack $ encodePretty $ preview _Value $ __response_body response
      in
        unwords [paint color blue $ trunc time, uid, "Response"]
          ++ "\n" ++ json
  , __http_error = \time uid err ->
      case triageHttpException err of
        Nothing -> unwords [paint color red $ trunc time, show err]
        Just (code,json) ->
          unwords [paint color red $ trunc time, uid, "HTTP Error Response", code]
            ++ "\n" ++ json
  }

triageHttpException :: HttpException -> Maybe (String, String)
triageHttpException e = case e of
  HttpExceptionRequest _ (StatusCodeException s r) -> do
    json <- decode $ fromStrict r
    let status = s ^. Wreq.responseStatus 
    return (show status, unpack $ encodePretty (json :: Value))
  _ -> Nothing
