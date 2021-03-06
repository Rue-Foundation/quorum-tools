{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module QuorumTools.Control where

import           Control.Concurrent            (threadDelay)
import           Control.Concurrent.Async      (Async, async, waitEitherCancel)
import qualified Control.Concurrent.Async.Pool as Pool
import           Control.Concurrent.MVar       (newEmptyMVar, takeMVar,
                                                tryPutMVar)
import           Control.Concurrent.STM        (STM, atomically)
import           Control.Concurrent.STM.TChan  (TChan, dupTChan, newTChan,
                                                readTChan, writeTChan)
import           Control.Concurrent.STM.TMVar  (TMVar, newTMVar, putTMVar,
                                                readTMVar, swapTMVar,
                                                takeTMVar)
import           Control.Exception             (bracket)
import           Control.Monad                 (forever, (<$!>))
import           Control.Monad.Loops           (untilJust)
import           Control.Monad.Managed         (Managed, MonadManaged, with)
import           Data.Foldable                 (for_, toList, traverse_)
import           Data.Maybe                    (fromJust)
import           Data.Monoid                   (Last (Last), getLast)
import           Data.Monoid.Same              (Same (..), allSame)
import           Data.Time.Units               (TimeUnit, toMicroseconds)
import           Data.Vector                   (Vector)
import qualified Data.Vector                   as V
import           Turtle                        (Fold (..), MonadIO, fork,
                                                liftIO, void, wait)

data Behavior a = Behavior (TChan a) (TMVar (Last a))

-- | Await fulfillment of all asyncs before continuing.
--
-- A "join point".
awaitAll :: (MonadIO m, Traversable t) => t (Async a) -> m ()
awaitAll = liftIO . traverse_ wait

-- | Execute an action before exiting. Exception safe.
--
-- @
--     onExit (putStrLn "exited!") $ \_ -> { code }
-- @
onExit :: IO () -> (() -> IO r) -> IO r
onExit action = bracket (pure ()) (const action)

timer :: (TimeUnit t, MonadIO m) => t -> m (Async ())
timer = liftIO . async . threadDelay . fromIntegral . toMicroseconds

-- | @(find' predicate)@ returns the first @Just@ predicate result or 'Nothing'
-- if no element satisfies the predicate
find' :: (a -> Maybe b) -> Fold a (Maybe b)
find' predicate = Fold step Nothing id where
  step accum a =
    let match = predicate a
    in case (accum, match) of
         (Just _b, _)       -> accum
         (Nothing, Just _b) -> match
         (Nothing, Nothing) -> Nothing

event :: forall m e. MonadManaged m => e -> m (Async e, IO ())
event e = do
  mvar <- liftIO newEmptyMVar
  occurred <- fork $ takeMVar mvar
  let fire = void $ tryPutMVar mvar e
  pure (occurred, fire)

-- | Creates a stream of values for many publishers to update, and many
-- consumers to subscribe (to value changes) or observe the current value.
behavior :: (MonadIO m) => m (Behavior a)
behavior = liftIO $ atomically $ Behavior <$> newTChan <*> newTMVar mempty

transition :: MonadIO m => Behavior a -> (Last a -> a) -> m ()
transition (Behavior tc tm) f = liftIO $ atomically $ do
  v <- takeTMVar tm
  let v' = f v
  putTMVar tm $ Last $ Just v'
  writeTChan tc v'

stmSubscribe :: Behavior a -> STM (TChan a)
stmSubscribe (Behavior chan _) = dupTChan chan

subscribe :: MonadIO m => Behavior a -> m (TChan a)
subscribe = liftIO . atomically . stmSubscribe

stmObserve :: Behavior a -> STM (Last a)
stmObserve (Behavior _ mvar) = readTMVar mvar

observe :: (MonadIO m) => Behavior a -> m (Last a)
observe = liftIO . atomically . stmObserve

watch :: MonadManaged m => Behavior a -> (a -> Maybe b) -> m (Async b)
watch b decide = do
  chan <- subscribe b
  fork $ liftIO $ untilJust $ decide <$> atomically (readTChan chan)

nextFrom :: MonadManaged m => Behavior a -> m (Async a)
nextFrom b = watch b Just

mapB :: (MonadManaged m) => (a -> b) -> Behavior a -> m (Behavior b)
mapB f upstream = do
    downstream <- behavior
    void $ forkReplication downstream
    return downstream

  where
    forkReplication downstream@(Behavior _ downstreamTm) = fork $ do
      chan <- atomically $ do
        mv0 <- stmObserve upstream
        void $ swapTMVar downstreamTm (f <$!> mv0)
        stmSubscribe upstream
      forever $ do
        val <- atomically $ readTChan chan
        -- NOTE: we publish downstream asychronously here
        let val' = f $! val
        transition downstream (const val')

-- We use Vectors here for efficient update by index. If 'Behavior' was a
-- 'Monad' then we could return the same @Traversable t@ instead.
combine :: forall a m t. (MonadManaged m, Traversable t)
        => t (Behavior a)
        -> m (Behavior (Vector (Last a)))
combine upstreams = do
    downstream <- behavior
    startReplication downstream
    return downstream

  where
    startReplication :: Behavior (Vector (Last a)) -> m ()
    startReplication downstream@(Behavior _ downstreamTm) = do
      chans <- fmap toList $ liftIO $ atomically $ do
        mv0s <- traverse stmObserve upstreams
        void $ swapTMVar downstreamTm $ Last $ Just $ V.fromList $ toList mv0s
        traverse stmSubscribe upstreams
      for_ (zip [(0 :: Int)..] chans) $ \(i, chan) -> fork $ forever $ do
        val <- atomically $ readTChan chan
        -- NOTE: we publish downstream asychronously here
        transition downstream $ (V.// [(i, Last $ Just val)]) . fromJust . getLast

-- | Yields the results in Right only when all 'Behavior's have produced a
-- value, and they are all the same.
convergence :: forall m t time a
             . (MonadManaged m, Traversable t, TimeUnit time, Eq a)
            => time
            -> t (Behavior a)
            -> m (Async (Either (Vector (Last a)) a))
convergence time upstreams = do
    updates <- combine upstreams
    fork $ untilJust $ raceTimeout updates

  where
    -- @Nothing@ means the timeout was interrupted
    -- @Just@ means the timer ran to completion without interruption
    raceTimeout :: Behavior (Vector (Last a))
                -> IO (Maybe (Either (Vector (Last a)) a))
    raceTimeout changes = unsafeDischargeManaged $ do
      timeout <- timer time
      nextChange <- nextFrom changes
      winner <- liftIO $ waitEitherCancel timeout nextChange
      case winner of
        Right _change -> return Nothing
        Left () -> do
          mvals <- observe changes
          case mvals of
            Last Nothing ->
              error "impossible lack of last value from combined behavior"
            Last (Just vals) -> return $ Just $ case allSame vals of
              DegenerateSame -> Left V.empty
              Same (Last Nothing) -> Left vals
              Same (Last (Just val)) -> Right val
              NotSame _ _ -> Left vals

    unsafeDischargeManaged :: Managed r -> IO r
    unsafeDischargeManaged = flip with pure

timeLimit :: (MonadManaged m, TimeUnit t) => t -> Async a -> m (Async (Maybe a))
timeLimit duration future = do
  timeout <- timer duration
  fork $ either (const Nothing) Just <$> waitEitherCancel timeout future

--
-- Bounded concurrency
--

mapConcurrentlyB :: Traversable t => Int -> (a -> IO b) -> t a -> IO (t b)
mapConcurrentlyB n f args = Pool.withTaskGroup n $ \group -> do
  Pool.mapTasks group (fmap f args)

forConcurrentlyB :: Traversable t => Int -> t a -> (a -> IO b) -> IO (t b)
forConcurrentlyB bound = flip (mapConcurrentlyB bound)
