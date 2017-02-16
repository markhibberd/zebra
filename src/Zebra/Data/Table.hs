{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
module Zebra.Data.Table (
    Table(..)
  , Column(..)

  , TableError(..)
  , ValueError(..)

  , encodingOfTable
  , encodingOfColumn

  , tableOfMaybeValue
  , tableOfValue
  , tableOfStruct

  , valuesOfTable

  , concatTables
  , concatColumns
  , appendTables
  , appendColumns
  , splitAtTable
  , splitAtColumn
  ) where

import           Control.Monad.State.Strict (MonadState(..))
import           Control.Monad.Trans.State.Strict (State, runState)

import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.Text.Encoding as T
import           Data.Typeable (Typeable)

import           GHC.Generics (Generic)

import           P

import           X.Control.Monad.Trans.Either (EitherT, runEitherT, hoistEither, left)
import qualified X.Data.ByteString.Unsafe as B
import qualified X.Data.Vector as Boxed
import qualified X.Data.Vector.Generic as Generic
import qualified X.Data.Vector.Storable as Storable
import           X.Text.Show (gshowsPrec)

import           Zebra.Data.Core
import           Zebra.Data.Encoding
import           Zebra.Data.Fact
import           Zebra.Data.Schema


data Table =
  Table {
      tableRowCount :: !Int
    , tableColumns :: !(Boxed.Vector Column)
    } deriving (Eq, Ord, Generic, Typeable)

data Column =
    ByteColumn !ByteString
  | IntColumn !(Storable.Vector Int64)
  | DoubleColumn !(Storable.Vector Double)
  | ArrayColumn !(Storable.Vector Int64) !Table
    deriving (Eq, Ord, Generic, Typeable)

data TableError =
    TableSchemaMismatch !Value !Schema
  | TableRequiredFieldMissing !Schema
  | TableCannotConcatEmpty
  | TableAppendColumnsMismatch !Column !Column
  | TableStructFieldsMismatch !(Boxed.Vector Value) !(Boxed.Vector FieldSchema)
  | TableEnumVariantMismatch !Int !Value !(Boxed.Vector VariantSchema)
    deriving (Eq, Ord, Show, Generic, Typeable)

data ValueError =
    ValueExpectedByteColumn !Column
  | ValueExpectedIntColumn !Column
  | ValueExpectedDoubleColumn !Column
  | ValueExpectedArrayColumn !Column
  | ValueStringLengthMismatch !Int !Int
  | ValueListLengthMismatch !Int !Int
  | ValueEnumVariantMismatch !Int !(Boxed.Vector VariantSchema)
  | ValueNoMoreColumns
  | ValueLeftoverColumns !Encoding
    deriving (Eq, Ord, Show, Generic, Typeable)

instance Show Table where
  showsPrec =
    gshowsPrec

instance Show Column where
  showsPrec =
    gshowsPrec

tableOfMaybeValue :: Schema -> Maybe' Value -> Either TableError Table
tableOfMaybeValue schema = \case
  Nothing' ->
    pure $ defaultOfSchema schema
  Just' value ->
    tableOfValue schema value

tableOfValue :: Schema -> Value -> Either TableError Table
tableOfValue schema =
  case schema of
    BoolSchema -> \case
      BoolValue False ->
        pure $ singletonInt 0
      BoolValue True ->
        pure $ singletonInt 1
      value ->
        Left $ TableSchemaMismatch value schema

    Int64Schema -> \case
      Int64Value x ->
        pure . singletonInt $ fromIntegral x
      value ->
        Left $ TableSchemaMismatch value schema

    DoubleSchema -> \case
      DoubleValue x ->
        pure $ singletonDouble x
      value ->
        Left $ TableSchemaMismatch value schema

    StringSchema -> \case
      StringValue x ->
        pure . singletonString $ T.encodeUtf8 x
      value ->
        Left $ TableSchemaMismatch value schema

    DateSchema -> \case
      DateValue x ->
        pure . singletonInt . fromIntegral $ fromDay x
      value ->
        Left $ TableSchemaMismatch value schema

    ListSchema ischema -> \case
      ListValue xs -> do
        vs0 <- traverse (tableOfValue ischema) xs
        vs1 <- concatTables vs0
        pure . Table 1 . Boxed.singleton $
          ArrayColumn (Storable.singleton . fromIntegral $ Boxed.length xs) vs1
      value ->
        Left $ TableSchemaMismatch value schema

    StructSchema fields -> \case
      StructValue values ->
        tableOfStruct fields values
      value ->
        Left $ TableSchemaMismatch value schema

    EnumSchema variant0 variants -> \case
      EnumValue tag x -> do
        VariantSchema _ variant <- maybeToRight (TableEnumVariantMismatch tag x variants) $ lookupVariant tag variant0 variants
        xtable <- tableOfValue variant x
        pure . Table 1 $
          tableColumns (singletonInt $ fromIntegral tag) <>
          tableColumns xtable
      value ->
        Left $ TableSchemaMismatch value schema

tableOfStruct :: Boxed.Vector FieldSchema -> Boxed.Vector Value -> Either TableError Table
tableOfStruct fields values =
  if Boxed.length fields /= Boxed.length values then
    Left $ TableStructFieldsMismatch values fields
  else
    fmap (Table 1 . Boxed.concatMap tableColumns) $
    Boxed.zipWithM tableOfValue (fmap fieldSchema fields) values

------------------------------------------------------------------------

valuesOfTable :: Schema -> Table -> Either ValueError (Boxed.Vector Value)
valuesOfTable schema table0 =
  evalStateTable table0 $ popValueColumn schema

evalStateTable :: Table -> EitherT ValueError (State Table) a -> Either ValueError a
evalStateTable table0 m =
  let
    (result, table) =
      runState (runEitherT m) table0
  in
    if Boxed.null $ tableColumns table then
      result
    else
      Left . ValueLeftoverColumns $ encodingOfTable table

popColumn :: EitherT ValueError (State Table) Column
popColumn = do
  Table n xs <- get
  case xs Boxed.!? 0 of
    Just x -> do
      put . Table n $ Boxed.drop 1 xs
      pure x
    Nothing ->
      left ValueNoMoreColumns

popByteColumn :: EitherT ValueError (State Table) ByteString
popByteColumn =
  popColumn >>= \case
    ByteColumn xs ->
      pure xs
    x ->
      left $ ValueExpectedByteColumn x

popIntColumn :: EitherT ValueError (State Table) (Storable.Vector Int64)
popIntColumn =
  popColumn >>= \case
    IntColumn xs ->
      pure xs
    x ->
      left $ ValueExpectedIntColumn x

popDoubleColumn :: EitherT ValueError (State Table) (Storable.Vector Double)
popDoubleColumn =
  popColumn >>= \case
    DoubleColumn xs ->
      pure xs
    x ->
      left $ ValueExpectedDoubleColumn x

popArrayColumn ::
  (Storable.Vector Int64 -> EitherT ValueError (State Table) a) ->
  EitherT ValueError (State Table) a
popArrayColumn f =
  popColumn >>= \case
    ArrayColumn ns table0 ->
      hoistEither . evalStateTable table0 $ f ns
    x ->
      left $ ValueExpectedArrayColumn x

popBoolColumn :: EitherT ValueError (State Table) (Boxed.Vector Bool)
popBoolColumn =
  fmap (fmap (/= 0) . Boxed.convert) $ popIntColumn

popValueColumn :: Schema -> EitherT ValueError (State Table) (Boxed.Vector Value)
popValueColumn = \case
  BoolSchema ->
    fmap (fmap BoolValue) popBoolColumn

  Int64Schema ->
    fmap (fmap (Int64Value . fromIntegral) . Boxed.convert) popIntColumn

  DoubleSchema ->
    fmap (fmap DoubleValue . Boxed.convert) popDoubleColumn

  StringSchema ->
    popArrayColumn $ \ns -> do
      bs <- popByteColumn
      fmap (fmap $ StringValue . T.decodeUtf8) . hoistEither $ restring ns bs

  DateSchema ->
    fmap (fmap (DateValue . toDay . fromIntegral) . Boxed.convert) popIntColumn

  ListSchema schema ->
    popArrayColumn $ \ns -> do
      xs <- popValueColumn schema
      fmap (fmap ListValue) . hoistEither $ relist ns xs

  StructSchema fields ->
    if Boxed.null fields then do
      Table n _ <- get
      pure . Boxed.replicate n $ StructValue Boxed.empty
    else do
      xss <- traverse (popValueColumn . fieldSchema) fields
      pure . fmap StructValue $ Boxed.transpose xss

  EnumSchema variant0 variants -> do
    tags <- popIntColumn
    xss <- Boxed.transpose <$> traverse (popValueColumn . variantSchema) (Boxed.cons variant0 variants)

    let
      takeTag tag xs = do
        x <- maybeToRight (ValueEnumVariantMismatch tag $ Boxed.cons variant0 variants) $ xs Boxed.!? tag
        pure $ EnumValue tag x

    hoistEither $
      Boxed.zipWithM takeTag (fmap fromIntegral $ Boxed.convert tags) xss

restring :: Storable.Vector Int64 -> ByteString -> Either ValueError (Boxed.Vector ByteString)
restring ns bs =
  let
    !n =
      fromIntegral $ Storable.sum ns

    !m =
      B.length bs
  in
    if n /= m then
      Left $ ValueStringLengthMismatch n m
    else
      pure . B.unsafeSplits id bs $ Storable.map fromIntegral ns

relist :: Storable.Vector Int64 -> Boxed.Vector a -> Either ValueError (Boxed.Vector (Boxed.Vector a))
relist ns xs =
  let
    !n =
      fromIntegral $ Storable.sum ns

    !m =
      Boxed.length xs
  in
    if n /= m then
      Left $ ValueListLengthMismatch n m
    else
      pure . Generic.unsafeSplits id xs $ Storable.map fromIntegral ns

------------------------------------------------------------------------

encodingOfTable :: Table -> Encoding
encodingOfTable =
  encodingOfColumns . Boxed.toList . tableColumns

encodingOfColumns :: [Column] -> Encoding
encodingOfColumns =
  Encoding . fmap encodingOfColumn

encodingOfColumn :: Column -> ColumnEncoding
encodingOfColumn = \case
  ByteColumn _ ->
    ByteEncoding
  IntColumn _ ->
    IntEncoding
  DoubleColumn _ ->
    DoubleEncoding
  ArrayColumn _ table ->
    ArrayEncoding $ encodingOfTable table

concatTables :: Boxed.Vector Table -> Either TableError Table
concatTables xss0 =
  if Boxed.null xss0 then
    Left TableCannotConcatEmpty
  else
    let
      n :: Int
      n =
        Boxed.sum $ fmap tableRowCount xss0

      xss :: Boxed.Vector (Boxed.Vector Column)
      xss =
        fmap tableColumns xss0

      yss =
        Boxed.transpose xss
    in
      fmap (Table n) $
      traverse concatColumns yss

appendTables :: Table -> Table -> Either TableError Table
appendTables (Table n xs) (Table m ys) =
  Table (n + m) <$> Boxed.zipWithM appendColumns xs ys

concatColumns :: Boxed.Vector Column -> Either TableError Column
concatColumns xs =
  if Boxed.null xs then
    Left TableCannotConcatEmpty
  else
    Boxed.fold1M' appendColumns xs

appendColumns :: Column -> Column -> Either TableError Column
appendColumns x y =
  case (x, y) of
    (ByteColumn xs, ByteColumn ys) ->
      pure $ ByteColumn (xs <> ys)

    (IntColumn xs, IntColumn ys) ->
      pure $ IntColumn (xs <> ys)

    (DoubleColumn xs, DoubleColumn ys) ->
      pure $ DoubleColumn (xs <> ys)

    (ArrayColumn n xs, ArrayColumn m ys) ->
      ArrayColumn (n <> m) <$>
      concatTables (Boxed.fromList [xs, ys])

    (_, _) ->
      Left $ TableAppendColumnsMismatch x y

splitAtTable :: Int -> Table -> (Table, Table)
splitAtTable i0 (Table n fs) =
  let
    i =
      min n (max 0 i0)

    (as, bs) =
      Boxed.unzip $ Boxed.map (splitAtColumn i) fs
  in
    (Table i as, Table (n - i) bs)

splitAtColumn :: Int -> Column -> (Column, Column)
splitAtColumn i =
  \case
    ByteColumn vs
     -> bye ByteColumn $ B.splitAt i vs
    IntColumn vs
     -> bye IntColumn $ Storable.splitAt i vs
    DoubleColumn vs
     -> bye DoubleColumn $ Storable.splitAt i vs
    ArrayColumn len rec
     -> let (len1, len2) = Storable.splitAt i len
            nested_count = fromIntegral $ Storable.sum len1
            (rec1, rec2) = splitAtTable nested_count rec
        in  (ArrayColumn len1 rec1, ArrayColumn len2 rec2)
  where
   bye f = bimap f f

------------------------------------------------------------------------

emptyByte :: Table
emptyByte =
  Table 0 . Boxed.singleton $ ByteColumn B.empty

emptyInt :: Table
emptyInt =
  Table 0 . Boxed.singleton $ IntColumn Storable.empty

emptyDouble :: Table
emptyDouble =
  Table 0 . Boxed.singleton $ DoubleColumn Storable.empty

emptyArray :: Table -> Table
emptyArray vs =
  Table 0 . Boxed.singleton $ ArrayColumn Storable.empty vs

emptyOfSchema :: Schema -> Table
emptyOfSchema = \case
  BoolSchema ->
    emptyInt
  Int64Schema ->
    emptyInt
  DoubleSchema ->
    emptyDouble
  StringSchema ->
    emptyArray emptyByte
  DateSchema ->
    emptyInt
  ListSchema schema ->
    emptyArray $ emptyOfSchema schema
  StructSchema fields ->
    Table 0 $ Boxed.concatMap (tableColumns . emptyOfSchema . fieldSchema) fields
  EnumSchema variant0 variants ->
    Table 0 $
      tableColumns emptyInt <>
      Boxed.concatMap (tableColumns . emptyOfSchema . variantSchema) (Boxed.cons variant0 variants)

singletonInt :: Int64 -> Table
singletonInt =
  Table 1 . Boxed.singleton . IntColumn . Storable.singleton

singletonDouble :: Double -> Table
singletonDouble =
  Table 1 . Boxed.singleton . DoubleColumn . Storable.singleton

singletonString :: ByteString -> Table
singletonString bs =
  Table 1 .
  Boxed.singleton $
  ArrayColumn
    (Storable.singleton . fromIntegral $ B.length bs)
    (Table (B.length bs) . Boxed.singleton $ ByteColumn bs)

singletonEmptyList :: Table -> Table
singletonEmptyList =
  Table 1 . Boxed.singleton . ArrayColumn (Storable.singleton 0)

defaultOfSchema :: Schema -> Table
defaultOfSchema = \case
  BoolSchema ->
    singletonInt 0
  Int64Schema ->
    singletonInt 0
  DoubleSchema ->
    singletonDouble 0
  StringSchema ->
    singletonString B.empty
  DateSchema ->
    singletonInt 0
  ListSchema schema ->
    singletonEmptyList $ emptyOfSchema schema
  StructSchema fields ->
    Table 1 $ Boxed.concatMap (tableColumns . defaultOfSchema . fieldSchema) fields
  EnumSchema variant0 variants ->
    Table 1 $
      tableColumns (singletonInt 0) <>
      Boxed.concatMap (tableColumns . defaultOfSchema . variantSchema) (Boxed.cons variant0 variants)
