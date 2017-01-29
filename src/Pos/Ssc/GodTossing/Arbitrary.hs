{-# LANGUAGE UndecidableInstances #-}

-- | Arbitrary instances for GodTossing types.

module Pos.Ssc.GodTossing.Arbitrary
       ( CommitmentOpening (..)
       ) where

import qualified Data.HashMap.Strict              as HM
import           Test.QuickCheck                  (Arbitrary (..), elements, oneof)
import           Universum

import           Pos.Binary.Class                 (Bi)
import           Pos.Crypto                       (deterministicVssKeyGen, toPublic,
                                                   toVssPublicKey)
import           Pos.Ssc.GodTossing.Core          (Commitment, Opening,
                                                   VssCertificate (..),
                                                   genCommitmentAndOpening,
                                                   mkVssCertificate)
import           Pos.Ssc.GodTossing.Type          ()
import           Pos.Ssc.GodTossing.Types.Message (GtMsgContents (..), GtMsgTag (..))
import           Pos.Ssc.GodTossing.Types.Types   (GtGlobalState (..), GtPayload (..),
                                                   GtProof (..), GtSecretStorage (..),
                                                   SscBi)
import           Pos.Ssc.GodTossing.VssCertData   (VssCertData (..))
import           Pos.Types.Address                (addressHash)
import           Pos.Types.Arbitrary.Unsafe       ()
import           Pos.Types.Core                   (StakeholderId)
import           Pos.Util                         (asBinary)
import           Pos.Util.Arbitrary               (Nonrepeating (..), makeSmall, sublistN,
                                                   unsafeMakePool)
import           Pos.Util.Relay                   (DataMsg (..))
----------------------------------------------------------------------------
-- Core
----------------------------------------------------------------------------

-- | Pair of 'Commitment' and 'Opening'.
data CommitmentOpening = CommitmentOpening
    { coCommitment :: !Commitment
    , coOpening    :: !Opening
    } deriving Show

-- | Generate 50 commitment/opening pairs in advance
-- (see `Pos.Crypto.Arbitrary` for explanations)
commitmentsAndOpenings :: [CommitmentOpening]
commitmentsAndOpenings =
    map (uncurry CommitmentOpening) $
    unsafeMakePool "[generating Commitments and Openings for tests...]" 50 $
       genCommitmentAndOpening 1 (one (asBinary vssPk))
  where
    vssPk = toVssPublicKey $ deterministicVssKeyGen "aaaaaaaaaaaaaaaaaaaaaassss"
{-# NOINLINE commitmentsAndOpenings #-}

instance Arbitrary CommitmentOpening where
    arbitrary = elements commitmentsAndOpenings

instance Nonrepeating CommitmentOpening where
    nonrepeating n = sublistN n commitmentsAndOpenings

instance Arbitrary Commitment where
    arbitrary = coCommitment <$> arbitrary

instance Arbitrary Opening where
    arbitrary = coOpening <$> arbitrary

instance Arbitrary VssCertificate where
    arbitrary = mkVssCertificate <$> arbitrary <*> arbitrary <*> arbitrary

------------------------------------------------------------------------------------------
-- Gt (God Tossing) types
------------------------------------------------------------------------------------------

instance (Bi Commitment, Bi Opening, Bi VssCertificate) => Arbitrary GtProof where
    arbitrary = oneof [
                        CommitmentsProof <$> arbitrary <*> arbitrary
                      , OpeningsProof <$> arbitrary <*> arbitrary
                      , SharesProof <$> arbitrary <*> arbitrary
                      , CertificatesProof <$> arbitrary
                      ]

instance Bi Commitment =>
         Arbitrary GtPayload where
    arbitrary =
        makeSmall $
        oneof
            [ CommitmentsPayload <$> genCommitments <*> genVssCerts
            , OpeningsPayload <$> arbitrary <*> genVssCerts
            , SharesPayload <$> arbitrary <*> genVssCerts
            , CertificatesPayload <$> genVssCerts
            ]
      where
        genCommitments = HM.fromList . map toCommPair <$> arbitrary
        toCommPair signedComm@(pk, _, _) = (addressHash pk, signedComm)
        genVssCerts = HM.fromList . map toCertPair <$> arbitrary
        toCertPair vc = (addressHash $ vcSigningKey vc, vc)

instance Arbitrary VssCertData where
    arbitrary = makeSmall $ VssCertData
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

instance Bi Commitment => Arbitrary GtGlobalState where
    arbitrary = makeSmall $ GtGlobalState
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

instance SscBi => Arbitrary GtSecretStorage where
    arbitrary = GtSecretStorage <$> arbitrary <*> arbitrary <*> arbitrary

------------------------------------------------------------------------------------------
-- Message types
------------------------------------------------------------------------------------------

instance Arbitrary GtMsgTag where
    arbitrary = oneof [ pure CommitmentMsg
                      , pure OpeningMsg
                      , pure SharesMsg
                      , pure VssCertificateMsg
                      ]

instance (Bi Commitment) => Arbitrary GtMsgContents where
    arbitrary = oneof [ MCCommitment <$> arbitrary
                      , MCOpening <$> arbitrary
                      , MCShares <$> arbitrary
                      , MCVssCertificate <$> arbitrary
                      ]

instance Arbitrary (DataMsg StakeholderId GtMsgContents) where
    arbitrary = do
        sk <- arbitrary
        let pk = toPublic sk
        let dmKey = addressHash pk
        dmContents <-
            oneof
                [ MCCommitment <$> ((pk, , ) <$> arbitrary <*> arbitrary)
                , MCOpening <$> arbitrary
                , MCShares <$> arbitrary
                , MCVssCertificate <$>
                  (mkVssCertificate sk <$> arbitrary <*> arbitrary)
                ]
        return $ DataMsg {..}
