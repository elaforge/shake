{-# LANGUAGE RecordWildCards, BangPatterns, GADTs, UnboxedTuples #-}

-- Note that argument order is more like IORef than Map, because its mutable
module General.Ids(
    Ids, Id,
    empty, insert, lookup,
    null, size, sizeUpperBound,
    forWithKeyM_, for,
    toList, toMap
    ) where

import Data.IORef.Extra
import Data.Primitive.Array
import Control.Exception
import General.Intern(Id(..))
import Control.Monad.Extra
import Data.Maybe
import Data.Functor
import qualified Data.HashMap.Strict as Map
import Prelude hiding (lookup, null)
import GHC.IO(IO(..))
import GHC.Exts(RealWorld)


newtype Ids a = Ids (IORef (S a))

data S a = S
    {capacity :: {-# UNPACK #-} !Int -- ^ Number of entries in values, initially 0
    ,used :: {-# UNPACK #-} !Int -- ^ Capacity that has been used, assuming no gaps from index 0, initially 0
    ,values :: {-# UNPACK #-} !(MutableArray RealWorld (Maybe a))
    }


empty :: IO (Ids a)
empty = do
    let capacity = 0
    let used = 0
    values <- newArray capacity Nothing
    Ids <$> newIORef S{..}


sizeUpperBound :: Ids a -> IO Int
sizeUpperBound (Ids ref) = do
    S{..} <- readIORef ref
    return used


size :: Ids a -> IO Int
size (Ids ref) = do
    S{..} <- readIORef ref
    let go !acc i
            | i < 0 = return acc
            | otherwise = do
                v <- readArray values i
                if isJust v then go (acc+1) (i-1) else go acc (i-1)
    go 0 (used-1)


toMap :: Ids a -> IO (Map.HashMap Id a)
toMap ids = do
    mp <- Map.fromList <$> toListUnsafe ids
    return $! mp

forWithKeyM_ :: Ids a -> (Id -> a -> IO ()) -> IO ()
forWithKeyM_ (Ids ref) f = do
    S{..} <- readIORef ref
    let go !i | i >= used = return ()
              | otherwise = do
                v <- readArray values i
                whenJust v $ f $ Id $ fromIntegral i
                go $ i+1
    go 0

for :: Ids a -> (a -> b) -> IO (Ids b)
for (Ids ref) f = do
    S{..} <- readIORef ref
    values2 <- newArray capacity Nothing
    let go !i | i >= used = return ()
              | otherwise = do
                v <- readArray values i
                whenJust v $ \v -> writeArray values2 i $ Just $ f v
                go $ i+1
    go 0
    Ids <$> newIORef (S capacity used values2)


toListUnsafe :: Ids a -> IO [(Id, a)]
toListUnsafe (Ids ref) = do
    S{..} <- readIORef ref

    -- execute in O(1) stack
    -- see https://neilmitchell.blogspot.co.uk/2015/09/making-sequencemapm-for-io-take-o1-stack.html
    let index r i | i >= used = []
        index r i | IO io <- readArray values i = case io r of
            (# r, Nothing #) -> index r (i+1)
            (# r, Just v  #) -> (Id $ fromIntegral i, v) : index r (i+1)

    IO $ \r -> (# r, index r 0 #)


toList :: Ids a -> IO [(Id, a)]
toList ids = do
    xs <- toListUnsafe ids
    let demand (x:xs) = demand xs
        demand [] = ()
    evaluate $ demand xs
    return xs


null :: Ids a -> IO Bool
null ids = (== 0) <$> sizeUpperBound ids


insert :: Ids a -> Id -> a -> IO ()
insert (Ids ref) (Id i) v = do
    S{..} <- readIORef ref
    let ii = fromIntegral i
    if ii < capacity then do
        writeArray values ii $ Just v
        when (ii >= used) $ writeIORef' ref S{used=ii+1,..}
     else do
        c2 <- return $ max (capacity * 2) (ii + 10000)
        v2 <- newArray c2 Nothing
        copyMutableArray v2 0 values 0 capacity
        writeArray v2 ii $ Just v
        writeIORef' ref $ S c2 (ii+1) v2

lookup :: Ids a -> Id -> IO (Maybe a)
lookup (Ids ref) (Id i) = do
    S{..} <- readIORef ref
    let ii = fromIntegral i
    if ii < used then
        readArray values ii
     else
        return Nothing
