{-# LANGUAGE OverloadedStrings, TypeSynonymInstances, FlexibleInstances #-}
module Lib
    ( Message
    , send
    , Config
    , defConf
    , Payload
    ) where
import           Prelude hiding (concat, length)
import           Control.Lens           hiding ((.=))
import           Control.Retry (retrying)
import           Data.Aeson (ToJSON, FromJSON, toJSON, parseJSON, decode)
import           Data.Aeson.Types (Value(Object), (.:), (.=), object)
import           Data.Default.Class (def)
import           Data.Maybe (isNothing, Maybe)
import           Data.Text (Text)
import           Data.Vector (Vector, length, fromList)
import           Data.ByteString (ByteString, concat)
import           Network.Wreq (postWith, defaults, header, Options, responseBody)
import           Control.Monad.Trans.Except (ExceptT, runExceptT)
import           Data.Either (Either(Right), isLeft)
import           Control.Monad.Trans.State (StateT, evalStateT, get, put)
import           Control.Monad.IO.Class (liftIO)

type Payload = (Text, Text)
instance ToJSON Payload where
    toJSON (k, v) = object [
      k .= v
      ]

data Message a = Message {
  _registrationIDs       :: Vector String,
  _collapseKey           :: Maybe String,
  _data                  :: a,
  _delayWhileIdle        :: Maybe Bool,
  _ttl                   :: Int,
  _restrictedPackageName :: Maybe String,
  _dryRun                :: Maybe Bool
  }

instance ToJSON a => ToJSON (Message a) where
  toJSON (Message r ck d dwi t rpn dr) = object [
     "registration_ids" .= r
     , "collapse_key" .= ck
     , "data" .= d
     , "delay_while_idle" .= dwi
     , "time_to_live" .= t
     , "restricted_package_name" .= rpn
     , "dry_run" .= dr
     ]

data Response = Response {
  _multicastId  :: Integer,
  _success      :: Int,
  _failure      :: Int,
  _canonicalIds :: Int,
  _results      :: [Result]
  }

instance FromJSON Response where
  parseJSON (Object v) = Response <$>
                                v .: "multicast_id" <*>
                                v .: "success" <*>
                                v .: "failure" <*>
                                v .: "canonical_ids" <*>
                                v .: "results"

data Result = Result {
  _messageId      :: String,
  _registrationId :: String,
  _error          :: String
  }

instance FromJSON Result where
  parseJSON (Object v) = Result <$>
                               v .: "message_id" <*>
                               v .: "registration_id" <*>
                               v .: "error"

data Config = Config {
  _key     :: ByteString,
  _noRetry :: Int
  }

data GcmError = GcmError String | GcmJsonError | GcmFailedError [String]

type Gcm m = ExceptT GcmError m

type GcmState a = StateT (Message a) IO (Either GcmError Response)

defConf = Config "" 0

gcmSendEndpoint = "https://android.googleapis.com/gcm/send"
backoffInitialDelay = 1000
maxBackoffDelay = 1024000

send :: ToJSON a => Config -> Message a -> IO (Either GcmError Response)
send cfg msg = do
  ok <- chkMsg msg
  if ok then do
      let opts = defaults & header "Authorization" .~ [concat ["key=", _key cfg]]
                          & header "Content-Type" .~ ["application/json"]
      evalStateT (compute opts) msg
  else return $ Left (GcmError "Test")
  where
      compute opts' = retrying def cond $ \_ -> do
          msg' <- get
          liftIO $ send' opts' msg'
      cond _ mr =
          case mr of
            Left _ -> return True
            Right (Response _ _ _ _ r) -> do
                origMsg <- get
                let ids = failedIds r
                    msg = origMsg { _registrationIDs = fromList ids }
                put msg
                return False

send' :: ToJSON a => Options -> Message a -> IO (Either GcmError Response)
send' opts msg = do
  r <- postWith opts gcmSendEndpoint (toJSON msg)
  let body = r ^. responseBody
  maybeToEither $ decode body

maybeToEither :: Maybe Response -> IO (Either GcmError Response)
maybeToEither Nothing = return $ Left GcmJsonError
maybeToEither (Just r@(Response _ _ f _ rs))
    | f == 0 = return $ Right r
    | otherwise = return $ Left $ GcmFailedError $ failedIds rs

failedIds rs = map _registrationId [i | i <- rs, _error i == "Unavailable"]

chkMsg (Message v _ _ _ t _ _)
    | length v == 0 = return False
    | length v > 1000 = return False
    | t < 0 = return False
    | t > 2419200 = return False
    | otherwise = return True
