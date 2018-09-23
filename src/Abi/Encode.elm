module Abi.Encode
    exposing
        ( Encoding
        , functionCall
        , functionCallWithDebug
        , address
        , uint
        , int
        , bool
        , staticBytes
        , ipfsHash
        , custom
        , abiEncode
        )

{-| Encode before sending RPC Calls

@docs Encoding, functionCall, functionCallWithDebug

@docs address, uint, int, bool, staticBytes, ipfsHash, custom


# Low-Level

@docs abiEncode

-}

import Abi.Int as AbiInt
import BigInt exposing (BigInt)
import Eth.Types exposing (Hex, IPFSHash)
import Eth.Utils as EthUtils exposing (functionSig, ipfsToBytes32)
import Eth.Types exposing (Address)
import String.UTF8 as UTF8
import Hex
import Internal.Types as Internal
import Internal.Utils as IU exposing (..)


{-| Not yet implemented : Dynamic Bytes, String, List
-}
type Encoding
    = AddressE Address
    | UintE BigInt
    | IntE BigInt
    | BoolE Bool
    | DBytesE Hex
    | BytesE Hex
    | StringE String
    | ListE (List Encoding)
    | IPFSHashE IPFSHash
    | CustomE String


{-| -}
functionCall : String -> List Encoding -> Hex
functionCall =
    functionCall_ False


{-| -}
functionCallWithDebug : String -> List Encoding -> Hex
functionCallWithDebug =
    functionCall_ True



-- Encoders


{-| -}
address : Address -> Encoding
address =
    AddressE


{-| -}
uint : BigInt -> Encoding
uint =
    UintE



-- TODO if int is greater than max_int Err.
-- would require different API with Results


{-| -}
int : BigInt -> Encoding
int =
    IntE


{-| -}
bool : Bool -> Encoding
bool =
    BoolE


{-| -}
staticBytes : Hex -> Encoding
staticBytes =
    BytesE


{-| -}
dynamicBytes : Hex -> Encoding
dynamicBytes =
    DBytesE


{-| -}
string : String -> Encoding
string =
    StringE


{-| -}
ipfsHash : IPFSHash -> Encoding
ipfsHash =
    IPFSHashE


{-| -}
custom : String -> Encoding
custom =
    CustomE



-- Low Level


{-| -}
abiEncode : Encoding -> Hex
abiEncode =
    lowLevelEncode >> (\v -> lowLevelEncodeList [ v ]) >> Internal.Hex


{-| -}
abiEncodeList : List Encoding -> Hex
abiEncodeList =
    List.map lowLevelEncode >> lowLevelEncodeList >> Internal.Hex



-- Internal


{-| -}
functionCall_ : Bool -> String -> List Encoding -> Hex
functionCall_ isDebug sig encodings =
    let
        byteCodeEncodings =
            List.map lowLevelEncode encodings
                |> lowLevelEncodeList

        data_ =
            EthUtils.functionSig sig
                |> EthUtils.hexToString
                |> IU.remove0x
                |> \str -> str ++ byteCodeEncodings

        data =
            if isDebug then
                Debug.log ("Debug Contract Call " ++ sig) data_
            else
                data_
    in
        Internal.Hex data


{-| (Maybe (Size of Dynamic Value), Value)
-}
type alias LowLevelEncoding =
    ( Maybe Int, String )


{-| -}
toStaticLLEncoding : String -> LowLevelEncoding
toStaticLLEncoding strVal =
    ( Nothing
    , strVal
    )


{-| -}
toDynamicLLEncoding : String -> LowLevelEncoding
toDynamicLLEncoding strVal =
    ( Just <| String.length strVal // 2
    , padToMod64 strVal
    )


{-| -}
lowLevelEncode : Encoding -> LowLevelEncoding
lowLevelEncode enc =
    case enc of
        AddressE (Internal.Address address) ->
            IU.leftPadTo64 address
                |> toStaticLLEncoding

        UintE uint ->
            BigInt.toHexString uint
                |> IU.leftPadTo64
                |> toStaticLLEncoding

        IntE int ->
            AbiInt.toString int
                |> toStaticLLEncoding

        BoolE True ->
            IU.leftPadTo64 "1"
                |> toStaticLLEncoding

        BoolE False ->
            IU.leftPadTo64 "0"
                |> toStaticLLEncoding

        DBytesE (Internal.Hex hexString) ->
            toDynamicLLEncoding hexString

        BytesE (Internal.Hex hexString) ->
            IU.remove0x hexString
                |> IU.leftPadTo64
                |> toStaticLLEncoding

        StringE string ->
            stringToHex string
                |> toDynamicLLEncoding

        ListE encodings ->
            abiEncodeList encodings
                |> (\(Internal.Hex hexString) ->
                        toDynamicLLEncoding hexString
                   )

        IPFSHashE ipfsHash ->
            EthUtils.ipfsToBytes32 ipfsHash
                |> \(Internal.Hex zerolessHex) ->
                    zerolessHex
                        |> toStaticLLEncoding

        CustomE string ->
            IU.remove0x string
                |> toStaticLLEncoding


lowLevelEncodeList : List LowLevelEncoding -> String
lowLevelEncodeList vals =
    let
        reducer : LowLevelEncoding -> ( Int, String, String ) -> ( Int, String, String )
        reducer ( mLength, val ) ( dynValPointer, staticVals, dynamicVals ) =
            case mLength of
                Just length ->
                    let
                        newDynValPointer =
                            dynValPointer + 32 + (String.length val // 2)

                        newStaticVals =
                            Hex.toString dynValPointer
                                |> IU.leftPadTo64

                        newDynVals =
                            Hex.toString length
                                |> IU.leftPadTo64
                                |> (\lengthInHex -> lengthInHex ++ val)
                    in
                        ( newDynValPointer
                          -- newPointer - = previousPointer + (length of hexLengthWord) + (length of val words)
                        , staticVals ++ newStaticVals
                        , dynamicVals ++ newDynVals
                        )

                Nothing ->
                    ( dynValPointer
                    , staticVals ++ val
                    , dynamicVals
                    )
    in
        List.foldl reducer ( List.length vals * 32, "", "" ) vals
            |> (\( _, sVals, dVals ) -> sVals ++ dVals)



-- Helpers


{-| Right pads a string so (strLength % 64 == 0)
64 chars or 32 bytes is the size of an EVM word
-}
padToMod64 : String -> String
padToMod64 str =
    str ++ String.repeat (String.length str |> tillMod64) "0"


tillMod64 : Int -> Int
tillMod64 n =
    64 - (n % 64)


{-| Converts utf8 string to string of hex
-}
stringToHex : String -> String
stringToHex strVal =
    UTF8.toBytes strVal
        |> List.map Hex.toString
        |> String.join ""
