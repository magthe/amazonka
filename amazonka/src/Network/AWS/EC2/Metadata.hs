{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}

-- |
-- Module      : Network.AWS.EC2.Metadata
-- Copyright   : (c) 2013-2015 Brendan Hay
-- License     : Mozilla Public License, v. 2.0.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : provisional
-- Portability : non-portable (GHC extensions)
--
-- This module contains functions for retrieving various EC2 metadata from an
-- instance's local metadata endpoint using 'MonadIO' and not one of the AWS
-- specific transformers.
--
-- It is intended to be used when you need to make metadata calls prior to
-- initialisation of the 'Network.AWS.Env.Env'.
-- If you wish to retrieve instance metadata during normal operations
-- and are using either the 'Network.AWS.AWS' or 'Control.Monad.Trans.AWS.AWST'
-- monads, then prefer one of the 'Control.Monad.Trans.AWS.metadata' related
-- functions available there, as the functions in this module do not use the
-- underlying 'MonadFree' 'Network.AWS.Free.Command' DSL.
module Network.AWS.EC2.Metadata
    (
    -- * EC2 Instance Check
      isEC2

    -- * Retrieving Instance Data
    , dynamic
    , metadata
    , userdata

    -- ** Path Constructors
    , Dynamic   (..)
    , Metadata  (..)
    , Mapping   (..)
    , Info      (..)
    , Interface (..)
    ) where

import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8  as BS8
import qualified Data.ByteString.Lazy   as LBS
import           Data.Monoid
import qualified Data.Text              as Text
import           Network.AWS.Prelude    hiding (request)
import           Network.HTTP.Conduit

import           Prelude

data Dynamic
    = FWS
    -- ^ Value showing whether the customer has enabled detailed one-minute
    -- monitoring in CloudWatch.
    --
    -- Valid values: enabled | disabled.
    | Document
    -- ^ JSON containing instance attributes, such as instance-id,
    -- private IP address, etc.
    | PKCS7
    -- ^ Used to verify the document's authenticity and content against the
    -- signature.
    | Signature
      deriving (Eq, Ord, Show, Typeable)

instance ToText Dynamic where
    toText = \case
       FWS       -> "dynamic/fws/instance-monitoring"
       Document  -> "dynamic/instance-identity/document"
       PKCS7     -> "dynamic/instance-identity/pkcs7"
       Signature -> "dynamic/instance-identity/signature"

data Metadata
    = AMIId
    -- ^ The AMI ID used to launch the instance.
    | AMILaunchIndex
    -- ^ If you started more than one instance at the same time, this value
    -- indicates the order in which the instance was launched.
    -- The value of the first instance launched is 0.
    | AMIManifestPath
    -- ^ The path to the AMI's manifest file in Amazon S3.
    -- If you used an Amazon EBS-backed AMI to launch the instance,
    -- the returned result is unknown.
    | AncestorAMIIds
    -- ^ The AMI IDs of any instances that were rebundled to create this AMI.
    -- This value will only exist if the AMI manifest file contained an
    -- ancestor-amis key.
    | BlockDevice !Mapping
    -- ^ See: 'Mapping'
    | Hostname
    -- ^ The private hostname of the instance. In cases where multiple network
    -- interfaces are present, this refers to the eth0 device
    -- (the device for which the device number is 0).
    | IAM !Info
    -- ^ See: 'Info'
    | InstanceAction
    -- ^ Notifies the instance that it should reboot in preparation for bundling.
    -- Valid values: none | shutdown | bundle-pending.
    | InstanceId
    -- ^ The ID of this instance.
    | InstanceType
    -- ^ The type of instance.
    --
    -- See: @InstanceType@
    | KernelId
    -- ^ The ID of the kernel launched with this instance, if applicable.
    | LocalHostname
    -- ^ The private DNS hostname of the instance. In cases where multiple
    -- network interfaces are present, this refers to the eth0 device
    -- (the device for which the device number is 0).
    | LocalIPV4
    -- ^ The private IP address of the instance. In cases where multiple network
    -- interfaces are present, this refers to the eth0 device
    -- (the device for which the device number is 0).
    | MAC
    -- ^ The instance's media access control (MAC) address. In cases where
    -- multiple network interfaces are present, this refers to the eth0 device
    -- (the device for which the device number is 0).
    | Network !Text !Interface
    -- ^ See: 'Interface'
    | AvailabilityZone
    -- ^ The Availability Zone in which the instance launched.
    | ProductCodes
    -- ^ Product codes associated with the instance, if any.
    | PublicHostname
    -- ^ The instance's public DNS. If the instance is in a VPC, this category
    -- is only returned if the enableDnsHostnames attribute is set to true.
    -- For more information, see Using DNS with Your VPC.
    | PublicIPV4
    -- ^ The public IP address. If an Elastic IP address is associated with the
    -- instance, the value returned is the Elastic IP address.
    | OpenSSHKey
    -- ^ Public key. Only available if supplied at instance launch time.
    | RAMDiskId
    -- ^ The ID of the RAM disk specified at launch time, if applicable.
    | ReservationId
    -- ^ ID of the reservation.
    | SecurityGroups
    -- ^ The names of the security groups applied to the instance.
      deriving (Eq, Ord, Show, Typeable)

instance ToText Metadata where
    toText = \case
        AMIId            -> "meta-data/ami-id"
        AMILaunchIndex   -> "meta-data/ami-launch-index"
        AMIManifestPath  -> "meta-data/ami-manifest-path"
        AncestorAMIIds   -> "meta-data/ancestor-ami-ids"
        BlockDevice m    -> "meta-data/block-device-mapping/" <> toText m
        Hostname         -> "meta-data/hostname"
        IAM m            -> "meta-data/iam/" <> toText m
        InstanceAction   -> "meta-data/instance-action"
        InstanceId       -> "meta-data/instance-id"
        InstanceType     -> "meta-data/instance-type"
        KernelId         -> "meta-data/kernel-id"
        LocalHostname    -> "meta-data/local-hostname"
        LocalIPV4        -> "meta-data/local-ipv4"
        MAC              -> "meta-data/mac"
        Network n m      -> "meta-data/network/interfaces/macs/" <> toText n <> "/" <> toText m
        AvailabilityZone -> "meta-data/placement/availability-zone"
        ProductCodes     -> "meta-data/product-codes"
        PublicHostname   -> "meta-data/public-hostname"
        PublicIPV4       -> "meta-data/public-ipv4"
        OpenSSHKey       -> "meta-data/public-keys/0/openssh-key"
        RAMDiskId        -> "meta-data/ramdisk-id"
        ReservationId    -> "meta-data/reservation-id"
        SecurityGroups   -> "meta-data/security-groups"

data Mapping
    = AMI
    -- ^ The virtual device that contains the root/boot file system.
    | EBS !Int
    -- ^ The virtual devices associated with Amazon EBS volumes, if present.
    -- This value is only available in metadata if it is present at launch time.
    -- The N indicates the index of the Amazon EBS volume (such as ebs1 or ebs2).
    | Ephemeral !Int
    -- ^ The virtual devices associated with ephemeral devices, if present.
    -- The N indicates the index of the ephemeral volume.
    | Root
    -- ^ The virtual devices or partitions associated with the root devices,
    -- or partitions on the virtual device, where the root (/ or C:) file system
    -- is associated with the given instance.
    | Swap
    -- ^ The virtual devices associated with swap. Not always present.
      deriving (Eq, Ord, Show, Typeable)

instance ToText Mapping where
    toText = \case
        AMI         -> "ami"
        EBS       n -> "ebs"       <> toText n
        Ephemeral n -> "ephemeral" <> toText n
        Root        -> "root"
        Swap        -> "root"

data Interface
    = IDeviceNumber
    -- ^ The device number associated with that interface. Each interface must
    -- have a unique device number. The device number serves as a hint to device
    -- naming in the instance; for example, device-number is 2 for the eth2 device.
    | IIPV4Associations !Text
    -- ^ The private IPv4 addresses that are associated with each public-ip
    -- address and assigned to that interface.
    | ILocalHostname
    -- ^ The interface's local hostname.
    | ILocalIPV4s
    -- ^ The private IP addresses associated with the interface.
    | IMAC
    -- ^ The instance's MAC address.
    | IOwnerId
    -- ^ The ID of the owner of the network interface. In multiple-interface
    -- environments, an interface can be attached by a third party, such as
    -- Elastic Load Balancing. Traffic on an interface is always billed to
    -- the interface owner.
    | IPublicHostname
    -- ^ The interface's public DNS. If the instance is in a VPC, this category
    -- is only returned if the enableDnsHostnames attribute is set to true.
    -- For more information, see Using DNS with Your VPC.
    | IPublicIPV4s
    -- ^ The Elastic IP addresses associated with the interface. There may be
    -- multiple IP addresses on an instance.
    | ISecurityGroups
    -- ^ Security groups to which the network interface belongs. Returned only
    -- for instances launched into a VPC.
    | ISecurityGroupIds
    -- ^ IDs of the security groups to which the network interface belongs.
    -- Returned only for instances launched into a VPC. For more information on
    -- security groups in the EC2-VPC platform, see Security Groups for Your VPC.
    | ISubnetId
    -- ^ The ID of the subnet in which the interface resides. Returned only for
    -- instances launched into a VPC.
    | ISubnetIPV4_CIDRBlock
    -- ^ The CIDR block of the subnet in which the interface resides. Returned
    -- only for instances launched into a VPC.
    | IVPCId
    -- ^ The ID of the VPC in which the interface resides. Returned only for
    -- instances launched into a VPC.
    | IVPCIPV4_CIDRBlock
    -- ^ The CIDR block of the VPC in which the interface resides. Returned only
    -- for instances launched into a VPC.
      deriving (Eq, Ord, Show, Typeable)

instance ToText Interface where
    toText = \case
        IDeviceNumber         -> "device-number"
        IIPV4Associations ip  -> "ipv4-associations/" <> toText ip
        ILocalHostname        -> "local-hostname"
        ILocalIPV4s           -> "local-ipv4s"
        IMAC                  -> "mac"
        IOwnerId              -> "owner-id"
        IPublicHostname       -> "public-hostname"
        IPublicIPV4s          -> "public-ipv4s"
        ISecurityGroups       -> "security-groups"
        ISecurityGroupIds     -> "security-group-ids"
        ISubnetId             -> "subnet-id"
        ISubnetIPV4_CIDRBlock -> "subnet-ipv4-cidr-block"
        IVPCId                -> "vpc-id"
        IVPCIPV4_CIDRBlock    -> "vpc-ipv4-cidr-block"

data Info
    = Info'
    -- ^ Returns information about the last time the instance profile was updated,
    -- including the instance's LastUpdated date, InstanceProfileArn,
    -- and InstanceProfileId.
    | SecurityCredentials (Maybe Text)
    -- ^ Where role-name is the name of the IAM role associated with the instance.
    -- Returns the temporary security credentials.
    --
    -- See: 'Auth' for JSON deserialisation.
      deriving (Eq, Ord, Show, Typeable)

instance ToText Info where
    toText = \case
        Info'                 -> "info"
        SecurityCredentials r -> "security-credentials/" <> maybe mempty toText r

latest :: Text
latest = "http://169.254.169.254/latest/"

-- | Test whether the underlying host is running on EC2 by
-- making an HTTP request to @http://instance-data/latest@.
isEC2 :: MonadIO m => Manager -> m Bool
isEC2 m = liftIO (req `catch` err)
  where
    req = do
        !_ <- request m "http://instance-data/latest"
        return True

    err :: HttpException -> IO Bool
    err = const (return False)

-- | Retrieve the specified 'Dynamic' data.
--
-- Throws 'HttpException' if HTTP communication fails.
dynamic :: (MonadIO m, MonadThrow m) => Manager -> Dynamic -> m ByteString
dynamic m = get m . mappend latest . toText

-- | Retrieve the specified 'Metadata'.
--
-- Throws 'HttpException' if HTTP communication fails.
metadata :: (MonadIO m, MonadThrow m) => Manager -> Metadata -> m ByteString
metadata m = get m . mappend latest . toText

-- | Retrieve the user data. Returns 'Nothing' if no user data is assigned
-- to the instance.
--
-- Throws 'HttpException' if HTTP communication fails.
userdata :: (MonadIO m, MonadCatch m) => Manager -> m (Maybe ByteString)
userdata m = do
    x <- try $ get m (latest <> "user-data")
    case x of
        Right b                 -> return (Just b)
        Left (StatusCodeException s _ _)
            | fromEnum s == 404 -> return Nothing
        Left e                  -> throwM e

get :: (MonadIO m, MonadThrow m) => Manager -> Text -> m ByteString
get m url = liftIO (strip `liftM` request m url)
  where
    strip bs
        | BS8.isSuffixOf "\n" bs = BS8.init bs
        | otherwise              = bs

request :: Manager -> Text -> IO ByteString
request m url = do
    rq <- parseUrl (Text.unpack url)
    rs <- httpLbs rq m
    return . LBS.toStrict $ responseBody rs
