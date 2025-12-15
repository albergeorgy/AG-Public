#bash ./copy_vm.sh --sourceResourceGroup "active-directory-rg" --sourceSubscription "d5be0f2b-3f4c-4ab6-ba3a-bdc7037b1970" --destinationResourceGroup "vNet" --destinationSubscription "1eb57be6-448b-4adc-b7b7-470daa0e1c13" --destinationVnetName "AG6-vNwt" --destinationSubnetName "default" --vmName "JDSA-AD" --zone 2

#!/usr/bin/env bash
# Fixed version of copyVM.sh
# - Separates VM RG from Network RG
# - Always resolves subnet ID explicitly
# - Prevents empty --subnet errors
# - Works cross-subscription

set -euo pipefail

############################
# PARAMETERS
############################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sourceResourceGroup) SOURCE_RG="$2"; shift 2;;
    --sourceSubscription) SOURCE_SUB="$2"; shift 2;;
    --destinationResourceGroup) DEST_RG="$2"; shift 2;;
    --destinationSubscription) DEST_SUB="$2"; shift 2;;
    --destinationVnetName) DEST_VNET="$2"; shift 2;;
    --destinationSubnetName) DEST_SUBNET="$2"; shift 2;;
    --destinationNetworkResourceGroup) DEST_NET_RG="$2"; shift 2;;
    --vmName) VM_NAME="$2"; shift 2;;
    --zone) ZONE="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

############################
# VALIDATION
############################
: "${SOURCE_RG:?Missing --sourceResourceGroup}"
: "${SOURCE_SUB:?Missing --sourceSubscription}"
: "${DEST_RG:?Missing --destinationResourceGroup}"
: "${DEST_SUB:?Missing --destinationSubscription}"
: "${DEST_VNET:?Missing --destinationVnetName}"
: "${DEST_SUBNET:?Missing --destinationSubnetName}"
: "${VM_NAME:?Missing --vmName}"

# If network RG not provided, assume same as destination RG
DEST_NET_RG="${DEST_NET_RG:-$DEST_RG}"

NIC_NAME="${VM_NAME}-nic"

############################
# SOURCE VM INFO
############################
echo "[Source] Reading VM metadata"
az account set --subscription "$SOURCE_SUB"

VM_JSON=$(az vm show \
  --resource-group "$SOURCE_RG" \
  --name "$VM_NAME" \
  --output json)

VM_SIZE=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize')
IMAGE_REF=$(echo "$VM_JSON" | jq -r '.storageProfile.imageReference | "\(.publisher):\(.offer):\(.sku):\(.version)"')
OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')

############################
# DESTINATION NETWORK
############################
echo "[Destination] Resolving subnet"
az account set --subscription "$DEST_SUB"

SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$DEST_NET_RG" \
  --vnet-name "$DEST_VNET" \
  --name "$DEST_SUBNET" \
  --query id -o tsv)

if [[ -z "$SUBNET_ID" ]]; then
  echo "ERROR: Subnet not found. Check RG/VNET/Subnet names."
  exit 1
fi

############################
# CREATE NIC
############################
echo "[Destination] Creating NIC"
az network nic create \
  --resource-group "$DEST_RG" \
  --subscription "$DEST_SUB" \
  --name "$NIC_NAME" \
  --subnet "$SUBNET_ID"

############################
# ACCEPT IMAGE TERMS
############################
IFS=':' read -r PUBLISHER OFFER SKU VERSION <<< "$IMAGE_REF"

echo "[Destination] Accepting image terms (if required)"
az vm image terms accept \
  --publisher "$PUBLISHER" \
  --offer "$OFFER" \
  --sku "$SKU" \
  --subscription "$DEST_SUB" || true

############################
# CREATE VM
############################
echo "[Destination] Creating VM"
az vm create \
  --resource-group "$DEST_RG" \
  --subscription "$DEST_SUB" \
  --name "$VM_NAME" \
  --nics "$NIC_NAME" \
  --image "$IMAGE_REF" \
  --size "$VM_SIZE" \
  ${ZONE:+--zone "$ZONE"} \
  --os-disk-name "$OS_DISK_NAME" \
  --generate-ssh-keys

echo "SUCCESS: VM copy completed"
