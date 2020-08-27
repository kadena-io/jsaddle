{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.Run
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- |
--
-----------------------------------------------------------------------------

module Language.Javascript.JSaddle.Run (
  -- * Running JSM
#ifndef ghcjs_HOST_OS
  -- * Functions used to implement JSaddle using JSON messaging
    runJavaScript
  , newJson
  , sync
  , lazyValResult
  , freeSyncCallback
  , newSyncCallback'
  , newSyncCallback''
  , callbackToSyncFunction
  , callbackToAsyncFunction
  , syncPoint
  , getProperty
  , setProperty
  , getJson
  , getJsonLazy
  , callAsFunction'
  , callAsConstructor'
  , globalRef
#endif
) where

#ifndef ghcjs_HOST_OS
import Control.Exception (try, SomeException(..))
import Control.Monad (when, join, void, unless, forever)
import Control.Monad.Trans.Reader (runReaderT)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.STM (atomically)
import Control.Concurrent (myThreadId, forkIO, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM.TVar (writeTVar, readTVar, newTVarIO, modifyTVar', readTVarIO)
import Control.Concurrent.MVar
       (putMVar, takeMVar, newMVar, newEmptyMVar, modifyMVar, modifyMVar_, swapMVar, tryPutMVar)

import Data.Monoid ((<>))
import Data.Map (Map)
import Data.Maybe
import qualified Data.Map as M
import Data.IORef (newIORef)

import Language.Javascript.JSaddle.Types
--TODO: Handle JS exceptions
import Data.Foldable (forM_, traverse_)
import System.IO.Unsafe
import Language.Javascript.JSaddle.Monad (syncPoint)

-- | The RefId of the global object
globalRefId :: RefId
globalRefId = RefId 1

globalRef :: Ref
globalRef = unsafePerformIO $ Ref <$> newIORef globalRefId
{-# NOINLINE globalRef #-}

-- | The first dynamically-allocated RefId
initialRefId :: RefId
initialRefId = RefId 2

type CallbackResultId = ValId

type CallbackResult = JSVal

runJavaScript
  :: ([TryReq] -> IO ()) -- ^ Send a batch of requests to the JS engine; we assume that requests are performed in the order they are sent; requests received while in a synchronous block must not be processed until the synchronous block ends (i.e. until the JS side receives the final value yielded back from the synchronous block)
  -> IO ( [Rsp] -> IO () -- Responses must be able to continue coming in as a sync block runs, or else the caller must be careful to ensure that sync blocks are only run after all outstanding responses have been processed
        , SyncCommand -> IO [Either CallbackResultId TryReq]
        , JSContextRef
        )
runJavaScript = runJavaScriptInt (500 {- 0.5 ms -}) 100

runJavaScriptInt
  :: Int
  -- ^ Timeout for sending async requests in microseconds
  -> Int
  -- ^ Max size of async requests batch size
  -> ([TryReq] -> IO ())
  -- ^ See comments for runJavaScript
  -> IO ( [Rsp] -> IO ()
        , SyncCommand -> IO [Either CallbackResultId TryReq]
        , JSContextRef
        )
runJavaScriptInt sendReqsTimeout pendingReqsLimit sendReqsBatch = do
  nextRefId <- newTVarIO initialRefId
  nextGetJsonReqId <- newTVarIO $ GetJsonReqId 1
  getJsonReqs <- newTVarIO M.empty
  nextCallbackId <- newTVarIO $ CallbackId 1
  callbacks <- newTVarIO M.empty
  nextTryId <- newTVarIO $ TryId 1
  tries <- newTVarIO M.empty
  pendingResults <- newTVarIO M.empty
  yieldAccumVar <- newMVar [] -- Accumulates results that need to be yielded
  yieldReadyVar <- newEmptyMVar -- Filled when there is at least one item in yieldAccumVar
  -- Each value in the map corresponds to a value ready to be returned from the sync frame corresponding to its key
  -- INVARIANT: \(depth, readyFrames) -> all (< depth) $ M.keys readyFrames
  syncCallbackState <- newMVar (0, M.empty)
  syncState <- newMVar SyncState_InSync
  nextSyncReqId <- newTVarIO $ SyncReqId 1
  syncReqs <- newTVarIO mempty
  sendReqsBatchVar <- newMVar ()
  pendingReqs <- newTVarIO []
  pendingReqsCount <- newTVarIO (0 :: Int)
  let enqueueYieldVal val = do
        wasEmpty <- modifyMVar yieldAccumVar $ \old -> do
          let !new = val : old
          return (new, null old)
        when wasEmpty $ putMVar yieldReadyVar ()
      enterSyncFrame = modifyMVar syncCallbackState $ \(oldDepth, readyFrames) -> do
        let !newDepth = succ oldDepth
        return ((newDepth, readyFrames), newDepth)
      exitSyncFrame myDepth myRetVal = modifyMVar_ syncCallbackState $ \(oldDepth, oldReadyFrames) -> case oldDepth `compare` myDepth of
        LT -> error "should be impossible: trying to return from deeper sync frame than the current depth"
        -- We're the top frame, so yield our value to the caller
        EQ -> do
          let yieldAllReady :: Int -> Map Int CallbackResult -> CallbackResult -> IO (Int, Map Int CallbackResult)
              yieldAllReady depth readyFrames retVal = do
                -- Even though the valId is escaping, this is safe because we know that our yielded value will go out before any potential FreeVal request could go out
                flip runReaderT env $ unJSM $ withJSValId retVal $ \retValId -> do
                  JSM $ liftIO $ enqueueYieldVal $ Left retValId
                let !nextDepth = pred depth
                case M.maxViewWithKey readyFrames of
                  -- The parent frame is also ready to yield
                  Just ((k, nextRetVal), nextReadyFrames)
                    | k == nextDepth
                      -> yieldAllReady nextDepth nextReadyFrames nextRetVal
                  _ -> return (nextDepth, readyFrames)
          yieldAllReady oldDepth oldReadyFrames myRetVal
        -- We're not the top frame, so just store our value so it can be yielded later
        GT -> do
          let !newReadyFrames = M.insertWith (error "should be impossible: trying to return from a sync frame that has already returned") myDepth myRetVal oldReadyFrames
          return (oldDepth, newReadyFrames)
      yield = do
        takeMVar yieldReadyVar
        reverse <$> swapMVar yieldAccumVar []
      processRsp = traverse_ $ \case
        Rsp_GetJson getJsonReqId val -> do
          reqs <- atomically $ do
            reqs <- readTVar getJsonReqs
            writeTVar getJsonReqs $! M.delete getJsonReqId reqs
            return reqs
          forM_ (M.lookup getJsonReqId reqs) $ \resultVar -> do
            putMVar resultVar val
        Rsp_Result refId primVal -> do
          mResultVar <- atomically $ do
            resultVars <- readTVar pendingResults
            let mResultVar = M.lookup refId resultVars
            when (isJust mResultVar) $ do
              writeTVar pendingResults $! M.delete refId resultVars
            return mResultVar
          forM_ mResultVar $ \resultVar -> do
            putMVar resultVar primVal
        Rsp_CallAsync callbackId this args -> do
          mCallback <- fmap (M.lookup callbackId) $ atomically $ readTVar callbacks
          case mCallback of
            Just callback -> do
              _ <- forkIO $ void $ flip runJSM env $ do
                _ <- join $ callback <$> wrapJSVal this <*> traverse wrapJSVal args
                return ()
              return ()
            Nothing -> error $ "callback " <> show callbackId <> " called, but does not exist"
        --TODO: We will need a synchronous version of this anyway, so maybe we should just do it that way
        Rsp_FinishTry tryId tryResult -> do
          mThisTry <- atomically $ do
            currentTries <- readTVar tries
            writeTVar tries $! M.delete tryId currentTries
            return $ M.lookup tryId currentTries
          case mThisTry of
            Nothing -> putStrLn $ "Rsp_FinishTry: " <> show tryId <> " not found"
            Just thisTry -> putMVar thisTry =<< case tryResult of
              Left v -> Left <$> runReaderT (unJSM (wrapJSVal v)) env
              Right _ -> return $ Right ()
        Rsp_Sync syncReqId -> do
          mThisSync <- atomically $ do
            currentSyncReqs <- readTVar syncReqs
            writeTVar syncReqs $! M.delete syncReqId currentSyncReqs
            return $ M.lookup syncReqId currentSyncReqs
          case mThisSync of
            Nothing -> putStrLn $ "Rsp_Sync: " <> show syncReqId <> " not found"
            Just thisSync -> putMVar thisSync ()
      sendReqAsync req = do
        count <- atomically $ do
          modifyTVar' pendingReqs ((:) req)
          c <- readTVar pendingReqsCount
          writeTVar pendingReqsCount (succ c)
          pure (succ c)
        when (count > pendingReqsLimit) $ void $ tryPutMVar sendReqsBatchVar ()
      doSendReqs = forever $ do
        race_ (threadDelay sendReqsTimeout) (takeMVar sendReqsBatchVar)
        reqs <- atomically $ do
          writeTVar pendingReqsCount 0
          reqs <- readTVar pendingReqs
          writeTVar pendingReqs []
          pure $ reverse reqs
        unless (null reqs) $ sendReqsBatch reqs
      env = JSContextRef
        { _jsContextRef_sendReq = sendReqAsync
        , _jsContextRef_sendReqAsync = sendReqAsync
        , _jsContextRef_sendReqsBatchVar = sendReqsBatchVar
        , _jsContextRef_syncThreadId = Nothing
        , _jsContextRef_nextRefId = nextRefId
        , _jsContextRef_nextGetJsonReqId = nextGetJsonReqId
        , _jsContextRef_getJsonReqs = getJsonReqs
        , _jsContextRef_nextCallbackId = nextCallbackId
        , _jsContextRef_callbacks = callbacks
        , _jsContextRef_pendingResults = pendingResults
        , _jsContextRef_nextTryId = nextTryId
        , _jsContextRef_tries = tries
        , _jsContextRef_myTryId = TryId 0 --TODO
        , _jsContextRef_syncState = syncState
        , _jsContextRef_nextSyncReqId = nextSyncReqId
        , _jsContextRef_syncReqs = syncReqs
        , _jsContextRef_waitForResults = Nothing
        }
      processSyncCommand = \case
        SyncCommand_StartCallback callbackId this args -> do
          mCallback <- fmap (M.lookup callbackId) $ atomically $ readTVar callbacks
          case mCallback of
            Just (callback :: JSVal -> [JSVal] -> JSM JSVal) -> do
              myDepth <- enterSyncFrame
              _ <- forkIO $ do
                _ :: Either SomeException () <- try $ do
                  threadId <- myThreadId
                  syncStateLocal <- newMVar SyncState_InSync
                  let syncEnv = env { _jsContextRef_sendReq = enqueueYieldVal . Right
                                    , _jsContextRef_syncThreadId = Just threadId
                                    , _jsContextRef_syncState = syncStateLocal }
                  result <- flip runReaderT syncEnv $ unJSM $
                    join $ callback <$> wrapJSVal this <*> traverse wrapJSVal args --TODO: Handle exceptions that occur within the callback
                  exitSyncFrame myDepth result
                return ()
              yield
            Nothing -> error $ "sync callback " <> show callbackId <> " called, but does not exist"
        SyncCommand_Continue -> yield
  void $ forkIO doSendReqs
  return (processRsp, processSyncCommand, env)

#endif
