{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module System.Remote.Common
    (
      -- * Types
      Counters
    , Gauges
    , Labels
    , Server(..)
    , MetricStore(..)

    , Ref(..)

      -- * User-defined counters, gauges, and labels
    , getCounter
    , getGauge
    , getLabel

      -- * Sampling
    , Metrics(..)
    , sampleAll
    , Metric(..)
    , sampleCombined
    , sampleCounters
    , sampleCounter
    , sampleGauges
    , sampleGauge
    , sampleLabels
    , sampleLabel

    , buildMany
    , buildAll
    , buildCombined
    ) where

import Control.Applicative ((<$>))
import Control.Concurrent (ThreadId)
import Control.Monad (forM)
import qualified Data.Aeson.Encode as A
import Data.Aeson.Types ((.=))
import qualified Data.Aeson.Types as A
import qualified Data.ByteString.Lazy as L
import qualified Data.HashMap.Strict as M
import Data.IORef (IORef, atomicModifyIORef, readIORef)
import Data.Int (Int64)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified GHC.Stats as Stats
import Prelude hiding (read)

import System.Remote.Counter (Counter)
import qualified System.Remote.Counter.Internal as Counter
import System.Remote.Gauge (Gauge)
import qualified System.Remote.Gauge.Internal as Gauge
import System.Remote.Label (Label)
import qualified System.Remote.Label.Internal as Label

------------------------------------------------------------------------

-- Map of user-defined counters.
type Counters = M.HashMap T.Text Counter

-- Map of user-defined gauges.
type Gauges = M.HashMap T.Text Gauge

-- Map of user-defined labels.
type Labels = M.HashMap T.Text Label

-- | A handle that can be used to control the monitoring server.
-- Created by 'forkServer'.
data Server = Server {
      threadId :: {-# UNPACK #-} !ThreadId
    , metricStore :: {-# UNPACK #-} !MetricStore
    }

------------------------------------------------------------------------
-- * User-defined counters, gauges and labels

class Ref r t | r -> t where
    new :: IO r
    read :: r -> IO t

instance Ref Counter Int where
    new = Counter.new
    read = Counter.read

instance Ref Gauge Int where
    new = Gauge.new
    read = Gauge.read

instance Ref Label T.Text where
    new = Label.new
    read = Label.read

-- | Lookup a 'Ref' by name in the given map.  If no 'Ref' exists
-- under the given name, create a new one, insert it into the map and
-- return it.
getRef :: Ref r t
       => T.Text                      -- ^ 'Ref' name
       -> IORef (M.HashMap T.Text r)  -- ^ Server that will serve the 'Ref'
       -> IO r
getRef name mapRef = do
    empty <- new
    ref <- atomicModifyIORef mapRef $ \ m ->
        case M.lookup name m of
            Nothing  -> let m' = M.insert name empty m
                        in (m', empty)
            Just ref -> (m, ref)
    return ref
{-# INLINABLE getRef #-}

-- | Return the counter associated with the given name and server.
-- Multiple calls to 'getCounter' with the same arguments will return
-- the same counter.  The first time 'getCounter' is called for a
-- given name and server, a new, zero-initialized counter will be
-- returned.
getCounter :: T.Text  -- ^ Counter name
           -> Server  -- ^ Server that will serve the counter
           -> IO Counter
getCounter name server = getRef name (userCounters $ metricStore server)

-- | Return the gauge associated with the given name and server.
-- Multiple calls to 'getGauge' with the same arguments will return
-- the same gauge.  The first time 'getGauge' is called for a given
-- name and server, a new, zero-initialized gauge will be returned.
getGauge :: T.Text  -- ^ Gauge name
         -> Server  -- ^ Server that will serve the gauge
         -> IO Gauge
getGauge name server = getRef name (userGauges $ metricStore server)

-- | Return the label associated with the given name and server.
-- Multiple calls to 'getLabel' with the same arguments will return
-- the same label.  The first time 'getLabel' is called for a given
-- name and server, a new, empty label will be returned.
getLabel :: T.Text  -- ^ Label name
         -> Server  -- ^ Server that will serve the label
         -> IO Label
getLabel name server = getRef name (userLabels $ metricStore server)

------------------------------------------------------------------------
-- * Sampling

data MetricStore = MetricStore
    { userCounters :: !(IORef Counters)
    , userGauges   :: !(IORef Gauges)
    , userLabels   :: !(IORef Labels)
    }

-- | A sample of some metrics.
data Metrics = Metrics
    { metricsCounters :: !(M.HashMap T.Text Int)
    , metricsGauges   :: !(M.HashMap T.Text Int)
    , metricsLabels   :: !(M.HashMap T.Text T.Text)
    }

-- | Sample all metrics.
sampleAll :: MetricStore -> IO Metrics
sampleAll store = do
    time <- getTimeMs
    counters <- readAllRefs (userCounters store)
    gauges <- readAllRefs (userGauges store)
    labels <- readAllRefs (userLabels store)
    (gcCounters, gcGauges) <- partitionGcStats <$> getGcStats
    let allCounters = counters ++ gcCounters ++ [("server_timestamp_ms", time)]
        allGauges   = gauges ++ gcGauges
    return $! Metrics
        (M.fromList allCounters)
        (M.fromList allGauges)
        (M.fromList labels)
  where
    getTimeMs :: IO Int
    getTimeMs = (round . (* 1000)) `fmap` getPOSIXTime

-- | The kind of metrics that can be tracked.
data Metric = Counter {-# UNPACK #-} !Int
            | Gauge {-# UNPACK #-} !Int
            | Label {-# UNPACK #-} !T.Text

sampleCombined :: MetricStore -> IO (M.HashMap T.Text Metric)
sampleCombined store = do
    metrics <- sampleAll store
    -- This assumes that the same name wasn't used for two different
    -- metric types.
    return $! M.unions [M.map Counter (metricsCounters metrics),
                        M.map Gauge (metricsGauges metrics),
                        M.map Label (metricsLabels metrics)]

sampleCounters :: MetricStore -> IO (M.HashMap T.Text Int)
sampleCounters store = metricsCounters <$> sampleAll store

sampleCounter :: T.Text -> MetricStore -> IO (Maybe Int)
sampleCounter name store = do
    counters <- sampleCounters store
    return $! M.lookup name counters

sampleGauges :: MetricStore -> IO (M.HashMap T.Text Int)
sampleGauges store = metricsGauges <$> sampleAll store

sampleGauge :: T.Text -> MetricStore -> IO (Maybe Int)
sampleGauge name store = do
    gauges <- sampleGauges store
    return $! M.lookup name gauges

sampleLabels :: MetricStore -> IO (M.HashMap T.Text T.Text)
sampleLabels store = metricsLabels <$> sampleAll store

sampleLabel :: T.Text -> MetricStore -> IO (Maybe T.Text)
sampleLabel name store = do
    labels <- sampleLabels store
    return $! M.lookup name labels

------------------------------------------------------------------------
-- * JSON serialization

-- | All the stats exported by the server (i.e. GC stats plus user
-- defined counters).
data Stats = Stats
    !Stats.GCStats          -- GC statistics
    ![(T.Text, Json)]       -- Counters
    ![(T.Text, Json)]       -- Gauges
    ![(T.Text, Json)]       -- Labels
    {-# UNPACK #-} !Double  -- Milliseconds since epoch

instance A.ToJSON Stats where
    toJSON (Stats gcStats counters gauges labels t) = A.object $
        [ "server_timestamp_millis" .= t
        , "counters"                .= Assocs (json gcCounters ++ counters)
        , "gauges"                  .= Assocs (json gcGauges ++ gauges)
        , "labels"                  .= Assocs labels
        ]
      where
        (gcCounters, gcGauges) = partitionGcStats gcStats
        json = map (\ (x, y) -> (x, Json y))

-- | 'Stats' encoded as a flattened JSON object.
newtype Combined = Combined Stats

instance A.ToJSON Combined where
    toJSON (Combined (Stats s@(Stats.GCStats {..}) counters gauges labels t)) =
        A.object $
        [ "server_timestamp_millis"  .= t
        , "bytes_allocated"          .= bytesAllocated
        , "num_gcs"                  .= numGcs
        , "max_bytes_used"           .= maxBytesUsed
        , "num_bytes_usage_samples"  .= numByteUsageSamples
        , "cumulative_bytes_used"    .= cumulativeBytesUsed
        , "bytes_copied"             .= bytesCopied
        , "current_bytes_used"       .= currentBytesUsed
        , "current_bytes_slop"       .= currentBytesSlop
        , "max_bytes_slop"           .= maxBytesSlop
        , "peak_megabytes_allocated" .= peakMegabytesAllocated
        , "mutator_cpu_seconds"      .= mutatorCpuSeconds
        , "mutator_wall_seconds"     .= mutatorWallSeconds
        , "gc_cpu_seconds"           .= gcCpuSeconds
        , "gc_wall_seconds"          .= gcWallSeconds
        , "cpu_seconds"              .= cpuSeconds
        , "wall_seconds"             .= wallSeconds
        , "par_tot_bytes_copied"     .= gcParTotBytesCopied s
        , "par_avg_bytes_copied"     .= gcParTotBytesCopied s
        , "par_max_bytes_copied"     .= parMaxBytesCopied
        ] ++
        map (uncurry (.=)) counters ++
        map (uncurry (.=)) gauges ++
        map (uncurry (.=)) labels

-- | A list of string keys and JSON-encodable values.  Used to render
-- a list of key-value pairs as a JSON object.
newtype Assocs = Assocs [(T.Text, Json)]

instance A.ToJSON Assocs where
    toJSON (Assocs xs) = A.object $ map (uncurry (.=)) xs

-- | A group of either counters or gauges.
data Group = Group
     ![(T.Text, Json)]
    {-# UNPACK #-} !Double  -- Milliseconds since epoch

instance A.ToJSON Group where
    toJSON (Group xs t) =
        A.object $ ("server_timestamp_millis" .= t) : map (uncurry (.=)) xs

------------------------------------------------------------------------

-- | Get a snapshot of all values.  Note that we're not guaranteed to
-- see a consistent snapshot of the whole map.
readAllRefs :: Ref r t => IORef (M.HashMap T.Text r) -> IO [(T.Text, t)]
readAllRefs mapRef = do
    m <- readIORef mapRef
    forM (M.toList m) $ \ (name, ref) -> do
        val <- read ref
        return (name, val)
{-# INLINABLE readAllRefs #-}

-- Existential wrapper used for OO-style polymorphism.
data Json = forall a. A.ToJSON a => Json a

instance A.ToJSON Json where
    toJSON (Json x) = A.toJSON x

-- | Convert seconds to milliseconds.
toMs :: Double -> Int
toMs s = round (s * 1000.0)

-- | Partition GC statistics into counters and gauges.
partitionGcStats :: Stats.GCStats -> ([(T.Text, Int)], [(T.Text, Int)])
partitionGcStats s@(Stats.GCStats {..}) = (counters, gauges)
  where
    counters = [
          ("bytes_allocated"          , fromIntegral bytesAllocated)
        , ("num_gcs"                  , fromIntegral numGcs)
        , ("num_bytes_usage_samples"  , fromIntegral numByteUsageSamples)
        , ("cumulative_bytes_used"    , fromIntegral cumulativeBytesUsed)
        , ("bytes_copied"             , fromIntegral bytesCopied)
        , ("mutator_cpu_ms"           , toMs mutatorCpuSeconds)
        , ("mutator_wall_ms"          , toMs mutatorWallSeconds)
        , ("gc_cpu_ms"                , toMs gcCpuSeconds)
        , ("gc_wall_ms"               , toMs gcWallSeconds)
        , ("cpu_ms"                   , toMs cpuSeconds)
        , ("wall_ms"                  , toMs wallSeconds)
        ]
    gauges = [
          ("max_bytes_used"           , fromIntegral maxBytesUsed)
        , ("current_bytes_used"       , fromIntegral currentBytesUsed)
        , ("current_bytes_slop"       , fromIntegral currentBytesSlop)
        , ("max_bytes_slop"           , fromIntegral maxBytesSlop)
        , ("peak_megabytes_allocated" , fromIntegral peakMegabytesAllocated)
        , ("par_tot_bytes_copied"     , fromIntegral (gcParTotBytesCopied s))
        , ("par_avg_bytes_copied"     , fromIntegral (gcParTotBytesCopied s))
        , ("par_max_bytes_copied"     , fromIntegral parMaxBytesCopied)
        ]

------------------------------------------------------------------------

-- TODO: Move the sampling into 'buildMany'.

-- | Serve a collection of counters or gauges, as a JSON object.
buildMany :: A.ToJSON t => (M.HashMap T.Text t) -> IO L.ByteString
buildMany metrics = do
    return $! A.encode $ A.toJSON $ Assocs $ map (mapSnd Json) $
        M.toList metrics
{-# INLINABLE buildMany #-}

-- | Serve all counter, gauges and labels, built-in or not, as a
-- nested JSON object.
buildAll :: MetricStore -> IO L.ByteString
buildAll = buildCombined
-- We're keeping this function from b/w compat but it now behaves
-- as 'buildCombined'.

instance A.ToJSON Metric where
    toJSON (Counter n) = A.toJSON n
    toJSON (Gauge n)   = A.toJSON n
    toJSON (Label l)   = A.toJSON l

mapSnd :: (b -> c) -> (a, b) -> (a, c)
mapSnd f (x, y) = (x, f y)

buildCombined :: MetricStore -> IO L.ByteString
buildCombined store = do
    metrics <- sampleCombined store
    return $ A.encode $ A.toJSON $ Assocs $ map (mapSnd Json) $
        M.toList metrics

getGcStats :: IO Stats.GCStats
#if MIN_VERSION_base(4,6,0)
getGcStats = do
    enabled <- Stats.getGCStatsEnabled
    if enabled
        then Stats.getGCStats
        else return emptyGCStats

emptyGCStats :: Stats.GCStats
emptyGCStats = Stats.GCStats
    { bytesAllocated         = 0
    , numGcs                 = 0
    , maxBytesUsed           = 0
    , numByteUsageSamples    = 0
    , cumulativeBytesUsed    = 0
    , bytesCopied            = 0
    , currentBytesUsed       = 0
    , currentBytesSlop       = 0
    , maxBytesSlop           = 0
    , peakMegabytesAllocated = 0
    , mutatorCpuSeconds      = 0
    , mutatorWallSeconds     = 0
    , gcCpuSeconds           = 0
    , gcWallSeconds          = 0
    , cpuSeconds             = 0
    , wallSeconds            = 0
    , parTotBytesCopied      = 0
    , parMaxBytesCopied      = 0
    }
#else
getGcStats = Stats.getGCStats
#endif

------------------------------------------------------------------------
-- Utilities for working with timestamps

-- | Helper to work around rename in GHC.Stats in base-4.6.
gcParTotBytesCopied :: Stats.GCStats -> Int64
#if MIN_VERSION_base(4,6,0)
gcParTotBytesCopied = Stats.parTotBytesCopied
#else
gcParTotBytesCopied = Stats.parAvgBytesCopied
#endif
