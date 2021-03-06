{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
module Test.Zebra.Serial.Text.Schema where

import           Disorder.Jack (Property, quickCheckAll)
import           Disorder.Jack (gamble)

import           P

import           System.IO (IO)

import           Test.Zebra.Jack

import           Zebra.Serial.Text.Schema


prop_roundtrip_schema :: Property
prop_roundtrip_schema =
  gamble jTableSchema $
    trippingBoth (pure . encodeSchemaWith TextV0) (decodeSchema)

return []
tests :: IO Bool
tests =
  $quickCheckAll
