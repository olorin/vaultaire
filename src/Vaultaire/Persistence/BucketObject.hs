--
-- Data vault for metrics
--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the BSD licence.
--

{-# LANGUAGE InstanceSigs      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports    #-}
{-# LANGUAGE BangPatterns    #-}
{-# OPTIONS -fno-warn-type-defaults #-}

module Vaultaire.Persistence.BucketObject (
    formObjectLabel,
    appendVaultPoints,
    readVaultObject,

    -- for testing
    tidyOriginName
) where

import Blaze.ByteString.Builder
import Control.Exception
import "mtl" Control.Monad.Error ()
import Control.Monad.IO.Class
import Control.Monad
import Control.Applicative
import Data.ByteString (ByteString)
import Data.Time.Clock
import qualified Data.ByteString.Char8 as S
import Data.Char
import Data.Locator
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Serialize
import Data.Word
import System.Rados
import Control.Concurrent.Async
import Data.List

import Vaultaire.Conversion.Reader
import Vaultaire.Internal.CoreTypes
import Vaultaire.Persistence.Constants
import qualified Vaultaire.Serialize.DiskFormat as Disk

{-
    I'd really like to think there's an easier way of doing constants
-}

windowSize :: Word64
windowSize = fromIntegral __WINDOW_SIZE__

--
-- Use the relevant information from a point to find out what bucket
-- it belongs in.
--
formObjectLabel :: Origin -> ByteString -> Timestamp -> Label
formObjectLabel o s' t =
    Label l'
  where
    l' = S.intercalate "_" [__EPOCH__, o', s', t']
    (Origin o') = o
    t2 = t `div` (windowSize * nanoseconds)
    t' = S.pack $ show (t2 * windowSize)


tidyOriginName :: ByteString -> ByteString
tidyOriginName o' =
  let
    width = 10

    predicate :: Char -> Bool
    predicate c = isAscii c && isPrint c && (c /= '_')

    n' = S.append (S.filter predicate o') (S.replicate width ':')
  in
    S.take width n'


hashOriginName :: ByteString -> ByteString
hashOriginName o' =
    hashStringToLocator16a 6 o'



--
-- | Given a collection of points in the same source, write them down to Ceph.
--


--
-- The origin contents file is locked before entering here. Build a map of
-- labels to encoded points, then construct a list of asynchronous appends.
--
appendVaultPoints :: Map Label Builder -> Pool ()
appendVaultPoints m = do
    writes <- sequence $ Map.foldrWithKey asyncAppend [] m
    liftIO $ do
        asyncs <- forM writes $ \w -> async $ checkError w
        times <- mapM wait asyncs
        print (mean times)
        putStrLn "Got acks:"
        putStrLn $ "mean:     " ++ (show $ mean times)
        putStrLn $ "median:   " ++ (show $ median times)
        putStrLn $ "avgdev:   " ++ (show $ avgdev times)
  where
    asyncAppend (Label l') bB as =
        (runAsync . runObject l' $ append $ toByteString bB) : as

    checkError write_in_flight = do
        start <- liftIO getCurrentTime
        maybe_error <- waitSafe write_in_flight
        case maybe_error of
            Just err    -> liftIO $ throwIO err
            Nothing     -> liftIO $ do
                end <- liftIO getCurrentTime
                return . fromRational . toRational $ diffUTCTime end start

    avgdev :: (Floating a) => [a] -> a
    avgdev xs = mean $ map (\x -> abs(x - m)) xs
        where
                m = mean xs

    mean :: Floating a => [a] -> a
    mean x = fst $ foldl' (\(!m, !n) x -> (m+(x-m)/(n+1),n+1)) (0,0) x

    median :: (Floating a, Ord a) => [a] -> a
    median x | odd n  = head  $ drop (n `div` 2) x'
            | even n = mean $ take 2 $ drop i x'
                    where i = (length x' `div` 2) - 1
                          x' = sort x
                          n  = length x


{-
    This whole thing is a bit crazy. We should just merge it all into a single
    use of Data.Serialize.Get
-}

readVaultObject
    :: Origin
    -> SourceDict
    -> Timestamp
    -> Pool (Map Timestamp Point)
readVaultObject o s t =
    let
        s' = hashSourceDict s           -- FIXME lookup from Directory
        l  = formObjectLabel o s' t
        Label l' = l

    in do
        ey' <- runObject l' readFull    -- Pool (Either RadosError ByteString)

        case ey' of
            Left err        -> liftIO $ throwIO err
            Right y'        -> either error return $ process y' Map.empty

    where

--
-- First write wins. This is a crucial design property; we DO expect duplicate
-- writes as a consequence of the distributed system design of Vaultaire:
-- points are idempotent for a given timestamp; if we see another no need to
-- insert it. This also has an important security aspect: someone can
-- maliciously write later, but we will ignore it and thereby not destroy data.
--

        process :: ByteString -> Map Timestamp Point -> Either String (Map Timestamp Point)
        process y' m1 =
            if S.null y'
                then return m1
                else do
                    (p,z') <- readPoint2 y'
                    let k = timestamp p
                    let m2 = if Map.member k m1
                            then m1
                            else Map.insert k p m1

                    process z' m2


        readPoint2 :: ByteString -> Either String (Point, ByteString)
        readPoint2 x' = do
            ((VaultRecord _ pb), remainder') <- runGetState get x' 0
            return (convertVaultToPoint o s pb, remainder')


data VaultRecord = VaultRecord Disk.VaultPrefix Disk.VaultPoint

instance Serialize VaultRecord where
    put (VaultRecord prefix point) = do
        put prefix
        put point

    get = do
        prefix <- get
        let len = fromIntegral $ Disk.size prefix
        point <- isolate len get
        return $ VaultRecord prefix point



