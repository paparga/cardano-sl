{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications      #-}

-- | Server which handles blocks.

module Pos.Communication.Server.Block
       ( blockListeners

       , handleBlock
       , handleBlockHeader
       , handleBlockRequest
       ) where

import           Control.TimeWarp.Logging   (logDebug, logInfo, logNotice, logWarning)
import           Control.TimeWarp.Rpc       (BinaryP, MonadDialog)
import           Data.List.NonEmpty         (NonEmpty ((:|)))
import           Formatting                 (build, int, sformat, stext, (%))
import           Serokell.Util              (VerificationRes (..), listJson)
import           Universum

import           Pos.Communication.Types    (RequestBlock (..), ResponseMode,
                                             SendBlock (..), SendBlockHeader (..))
import           Pos.Communication.Util     (modifyListenerLogger)
import           Pos.Crypto                 (hash)
import           Pos.DHT                    (ListenerDHT (..), replyToNode)
import           Pos.Slotting               (getCurrentSlot)
import           Pos.Ssc.DynamicState.Types (SscDynamicState)
import qualified Pos.State                  as St
import           Pos.Statistics             (statlogReceivedBlock,
                                             statlogReceivedBlockHeader, statlogSentBlock)
import           Pos.Types                  (HeaderHash, headerHash)
import           Pos.WorkMode               (WorkMode)

-- | Listeners for requests related to blocks processing.
blockListeners :: (MonadDialog BinaryP m, WorkMode m) => [ListenerDHT m]
blockListeners =
    map (modifyListenerLogger "block")
        [ ListenerDHT handleBlock
        , ListenerDHT handleBlockHeader
        , ListenerDHT handleBlockRequest
        ]

handleBlock :: ResponseMode m => SendBlock SscDynamicState -> m ()
handleBlock (SendBlock block) = do
    statlogReceivedBlock block
    slotId <- getCurrentSlot
    pbr <- St.processBlock slotId block
    let blkHash :: HeaderHash SscDynamicState
        blkHash = headerHash block
    case pbr of
        St.PBRabort msg -> do
            let fmt =
                    "Block "%build%
                    " processing is aborted for the following reason: "%stext
            logWarning $ sformat fmt blkHash msg
        St.PBRgood (0, (_:|_)) -> logInfo $
            sformat ("Received block has been adopted: "%build) blkHash
        St.PBRgood (rollbacked, altChain) -> logNotice $
            sformat ("As a result of block processing rollback of "%int%
                     " blocks has been done and alternative chain has been adopted "%
                     listJson)
                     rollbacked (fmap headerHash altChain ::
                                        NonEmpty (HeaderHash SscDynamicState))
        St.PBRmore h -> do
            logInfo $ sformat
                ("After processing block "%build%", we need block "%build)
                blkHash h
            replyToNode $ RequestBlock h

handleBlockHeader
    :: ResponseMode m
    => SendBlockHeader SscDynamicState -> m ()
handleBlockHeader (SendBlockHeader header) = do
    statlogReceivedBlockHeader header'
    whenM checkUsefulness $ replyToNode (RequestBlock h)
  where
    header' = Right header
    h = hash header'
    checkUsefulness = do
        slotId <- getCurrentSlot
        verRes <- St.mayBlockBeUseful slotId header
        case verRes of
            VerFailure errors -> do
                let fmt =
                        "Ignoring header with hash "%build%
                        " for the following reasons: "%listJson
                let msg = sformat fmt h errors
                False <$ logDebug msg
            VerSuccess -> do
                let fmt = "Block header " % build % " considered useful"
                    msg = sformat fmt h
                True <$ logDebug msg

handleBlockRequest
    :: ResponseMode m
    => RequestBlock SscDynamicState -> m ()
handleBlockRequest (RequestBlock h) = do
    logDebug $ sformat ("Block "%build%" is requested") h
    maybe logNotFound sendBlockBack =<< St.getBlock h
  where
    logNotFound = logWarning $ sformat ("Block "%build%" wasn't found") h
    sendBlockBack block = do
        statlogSentBlock block
        logDebug $ sformat ("Sending block "%build%" in reply") h
        replyToNode $ SendBlock block
