#!/bin/bash

# Define color codes
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 --sourceResourceGroup  --sourceSubscription  --destinationResourceGroup  --destinationSubscription  --destinationVnetName  --destinationSubnetName  --zone  --vmName"
    exit 1
}

# Parse named parameters
while [ "$1" != "" ]; do
    case $1 in
        --sourceResourceGroup )      shift
                                     sourceResourceGroup=$1
                                     ;;
        --sourceSubscription )       shift
                                     sourceSubscription=$1
                                     ;;
        --vmName )                   shift
                                     vmName=$1
                                     ;;
        --zone )                     shift
                                     zone=$1
                                     ;;
        --destinationResourceGroup ) shift
                                     destinationResourceGroup=$1
                                     ;;
        --destinationSubscription )  shift
                                     destinationSubscription=$1
                                     ;;
        --destinationVnetName )      shift
                                     destinationVnetName=$1
                                     ;;
        --destinationSubnetName )    shift
                                     destinationSubnetName=$1
                                     ;;
        * )                          usage
                                     ;;
    esac
    shift
done

# Check if all parameters are provided
if [ -z "$sourceResourceGroup" ] || [ -z "$sourceSubscription" ] || [ -z "$vmName" ] || [ -z "$zone" ] || [ -z "$destinationResourceGroup" ] || [ -z "$destinationSubscription" ] || [ -z "$destinationVnetName" ] || [ -z "$destinationSubnetName" ]; then
    usage
fi

# Display the source and destination details
echo -e "[Source] VM: ${YELLOW}$vmName${NC} sub: ${YELLOW}$sourceSubscription${NC} rg: ${YELLOW}$sourceResourceGroup${NC}"
echo -e "[Destination] sub: ${YELLOW}$destinationSubscription${NC} rg: ${YELLOW}$destinationResourceGroup${NC} zone: ${YELLOW}$zone${NC} vnet: ${YELLOW}$destinationVnetName${NC} subnet: ${YELLOW}$destinationSubnetName${NC}"
echo .

# Set your current subscription for the source virtual machine
#echo " -> Az account set to $sourceSubscription"
#az account set --subscription $sourceSubscription

# Load variables about your virtual machine
echo " -> Getting Variables"
osType=$(az vm get-instance-view --resource-group $sourceResourceGroup --name $vmName --subscription $sourceSubscription --query 'storageProfile.osDisk.osType' --output tsv)

# offer = Your offer in Marketplace
offer=$(az vm get-instance-view --resource-group $sourceResourceGroup --name $vmName --subscription $sourceSubscription --query 'storageProfile.imageReference.offer' --output tsv)
plan=$(az vm get-instance-view --resource-group $sourceResourceGroup --name $vmName --subscription $sourceSubscription --query 'storageProfile.imageReference.sku' --output tsv)
publisher=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --name $vmName --query 'storageProfile.imageReference.publisher' --output tsv)

# Get information to create new virtual machine
planName=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'plan.name' --name $vmName --output tsv)
planProduct=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'plan.product' --name $vmName --output tsv)
planPublisher=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'plan.publisher' --name $vmName --output tsv)

# Additional VM Information
vmSize=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'hardwareProfile.vmSize' --name $vmName --output tsv)
vmGen=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'instanceView.hyperVGeneration' --name $vmName --output tsv)
licenseType=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'licenseType' --name $vmName --output tsv)

# NIC DNS
nicId=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query 'networkProfile.networkInterfaces[0].id' --name $vmName --output tsv)
if [ -z "$nicId" ]; then
    echo -e "${RED}Failed - No Nic Identity${NC}"
    exit 1
fi

nicAccNetworking=$(az network nic show -g $sourceResourceGroup --subscription $sourceSubscription -n $(basename "$nicId") --query 'enableAcceleratedNetworking' --output tsv)
nicName=$(az network nic show -g $sourceResourceGroup --subscription $sourceSubscription -n $(basename "$nicId") --query 'name' --output tsv)

# Set your subscription to the destination value
# echo " -> Az account set to $destinationSubscription"
# az account set --subscription $destinationSubscription

# Accept the terms from the Marketplace
if [ -n "$offer" ] && [ -n "$plan" ] && [ -n "$publisher" ]; then
    printf " -> Accepting Marketplace Offer: "
    output=$(az vm image terms accept --offer "$offer" --plan "$plan" --publisher "$publisher" --subscription $destinationSubscription)
    provisioningState=$(echo "$output" | jq -r '.accepted')
    if [ "$provisioningState" == "true" ]; then
        echo -e "${GREEN}true${NC} ($publisher:$offer:$plan:latest)"
    else
        echo -e "${RED}Not accepted${NC}"
        echo "$output" | jq -r
        exit 1
    fi
else
    echo " -> No Plan Required (Indicated by one or more required variables (offer, plan, publisher) are empty) - Skipping command execution."
fi

# Provision Network Adapter
printf " -> Provision Network Adapter: "
output=$(az network nic create -g $destinationResourceGroup --subscription $destinationSubscription --subnet $(az network vnet subnet show -g rg-network-cac --vnet-name $destinationVnetName -n $destinationSubnetName --subscription $destinationSubscription -o tsv --query id) -n $nicName --accelerated-networking $nicAccNetworking)
provisioningState=$(echo "$output" | jq -r '.NewNIC.provisioningState')
if [ "$provisioningState" == "Succeeded" ]; then
    echo -e " -> Network Adapter: ${GREEN}Provisioning succeeded${NC}"
else
    echo -e " -> Network Adapter: ${RED}Provisioning not succeeded${NC}"
    echo "$output" | jq -r
    exit 1
fi

# Deallocate the virtual machine
echo "Deallocating VM: $vmName"
az vm deallocate --resource-group $sourceResourceGroup --name $vmName --subscription $sourceSubscription


# Get the number of data disks
dataDiskCount=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query "storageProfile.dataDisks" --name $vmName --output JSON | jq length)

# Loop through each data disk
dataDiskInventory=""
dataDiskInventoryCaching=""
for ((i=0; i<$dataDiskCount; i++)); do
    # Get the data disk name
    diskName=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query "storageProfile.dataDisks[$i].name" --name $vmName --output tsv)
    diskCaching=$(az vm get-instance-view --resource-group $sourceResourceGroup --subscription $sourceSubscription --query "storageProfile.dataDisks[$i].caching" --name $vmName --output tsv)
    diskSku=$(az vm show --resource-group $sourceResourceGroup --subscription $sourceSubscription --name $vmName --query "storageProfile.dataDisks[$i].managedDisk.storageAccountType" --output tsv)

    if [ -z "$diskName" ]; then
        echo "diskName is empty"
        exit 1
    fi

    if [ -z "$diskSku" ]; then
        echo "! $diskSku Empty"
        exit 1
    fi

    dataDiskInventory="$dataDiskInventory $diskName"
    dataDiskInventoryCaching="$dataDiskInventoryCaching $i=$diskCaching"

    # Create a snapshot of the data disk
    printf " -> Provision Data Disk Snapshot $((i + 1)) of $dataDiskCount: "
    output=$(az snapshot create --resource-group $destinationResourceGroup --subscription $destinationSubscription --name "${diskName}-snapshot" --source "/subscriptions/$sourceSubscription/resourceGroups/$sourceResourceGroup/providers/Microsoft.Compute/disks/$diskName" --network-access-policy AllowAll)
    provisioningState=$(echo "$output" | jq -r '.provisioningState')
    if [ "$provisioningState" == "Succeeded" ]; then
        echo -e " -> Provision Data Disk Snapshot $((i + 1)) of $dataDiskCount: ${GREEN}Provisioning succeeded${NC}"
    else
        echo -e " -> Provision Data Disk Snapshot $((i + 1)) of $dataDiskCount: ${RED}Provisioning not succeeded${NC}"
        echo "$output" | jq -r
        exit 1
    fi
    
    # Create a disk from the snapshot
    printf " -> Provision Data Disk $((i + 1)) of $dataDiskCount: "
    output=$(az disk create --resource-group $destinationResourceGroup --subscription $destinationSubscription --name $diskName --source "/subscriptions/$destinationSubscription/resourceGroups/$destinationResourceGroup/providers/Microsoft.Compute/snapshots/${diskName}-snapshot" --zone $zone --sku $diskSku)
    provisioningState=$(echo "$output" | jq -r '.provisioningState')
    if [ "$provisioningState" == "Succeeded" ]; then
        echo -e " -> Provision Data Disk $((i + 1)) of $dataDiskCount: ${GREEN}Provisioning succeeded${NC}"
    else
        echo -e " -> Provision Data Disk $((i + 1)) of $dataDiskCount: ${RED}Provisioning not succeeded${NC}"
        echo "$output" | jq -r
        exit 1
    fi

    # Delete snapshot
    echo " -> Deleting Data Disk Snapshot $((i + 1)) of $dataDiskCount"
    az snapshot delete --resource-group $destinationResourceGroup --subscription $destinationSubscription --name "${diskName}-snapshot" --no-wait
done

# Get the name of the OS disk
diskName=$(az vm show --resource-group $sourceResourceGroup --subscription $sourceSubscription --name $vmName --query "storageProfile.osDisk.name" --output tsv)
diskSku=$(az vm show --resource-group $sourceResourceGroup --subscription $sourceSubscription --name $vmName --query "storageProfile.osDisk.managedDisk.storageAccountType" --output tsv)

if [ -z "$diskSku" ]; then
    echo "! $diskSku Empty"
    exit 1
fi

# Create a snapshot of the OS disk
printf " -> Creating OS Disk Snapshot: "
output=$(az snapshot create --resource-group $destinationResourceGroup --subscription $destinationSubscription --name "${diskName}-snapshot" --source "/subscriptions/$sourceSubscription/resourceGroups/$sourceResourceGroup/providers/Microsoft.Compute/disks/$diskName" --network-access-policy AllowAll)
provisioningState=$(echo "$output" | jq -r '.provisioningState')
if [ "$provisioningState" == "Succeeded" ]; then
    echo -e " -> Creating OS Disk Snapshot: ${GREEN}Provisioning succeeded${NC}"
else
    echo -e " -> Creating OS Disk Snapshot: ${RED}Provisioning not succeeded${NC}"
    echo "$output" | jq -r
    exit 1
fi

# Create the OS disk from the snapshot
printf " -> Creating OS Disk: "
output=$(az disk create --resource-group $destinationResourceGroup --subscription $destinationSubscription --name $diskName --source "/subscriptions/$destinationSubscription/resourceGroups/$destinationResourceGroup/providers/Microsoft.Compute/snapshots/${diskName}-snapshot" --os-type $osType --zone $zone --hyper-v-generation $vmGen --sku $diskSku)
provisioningState=$(echo "$output" | jq -r '.provisioningState')
if [ "$provisioningState" == "Succeeded" ]; then
    echo -e " -> Creating OS Disk: ${GREEN}Provisioning succeeded${NC}"
else
    echo -e " -> Creating OS Disk: ${RED}Provisioning not succeeded${NC}"
    echo "$output" | jq -r
    exit 1
fi

# Delete snapshot
echo " -> Deleting OS Disk Snapshot"
az snapshot delete --resource-group $destinationResourceGroup --subscription $destinationSubscription --name "${diskName}-snapshot" --no-wait

# Verify the terms from the Marketplace
if [ -n "$offer" ] && [ -n "$plan" ] && [ -n "$publisher" ]; then
    printf " -> Verifying Terms of Marketplace Offer: "
    output=$(az vm image terms show --offer "$offer" --plan "$plan" --publisher "$publisher" --subscription $destinationSubscription)
    provisioningState=$(echo "$output" | jq -r '.accepted')
    if [ "$provisioningState" == "true" ]; then
        echo -e "-> Verifying Terms of Marketplace Offer: ${GREEN}Provisioning succeeded${NC}"
    else
        echo -e "-> Verifying Terms of Marketplace Offer: ${RED}Not accepted${NC}"
        echo "$output" | jq -r
        exit 1
    fi
else
    echo " -> No Plan Required (Indicated by one or more required variables (offer, plan, publisher) are empty) - Skipping command execution."
fi

# Create virtual machine from disk
command="az vm create --resource-group $destinationResourceGroup --subscription $destinationSubscription --name $vmName --nics $nicName"

if [ -n "$planName" ]; then
    command="$command --plan-name $planName"
fi
if [ -n "$planProduct" ]; then
    command="$command --plan-product $planProduct"
fi
if [ -n "$planPublisher" ]; then
    command="$command --plan-publisher $planPublisher"
fi

if [ -n "$dataDiskInventory" ]; then
    command="$command --attach-data-disks $dataDiskInventory"
fi
if [ -n "$dataDiskInventoryCaching" ]; then
    command="$command --data-disk-caching $dataDiskInventoryCaching"
fi
command="$command --attach-os-disk \"/subscriptions/$destinationSubscription/resourceGroups/$destinationResourceGroup/providers/Microsoft.Compute/disks/$diskName\""
command="$command --os-type $osType"
command="$command --public-ip-address \"\""
command="$command --size $vmSize"
command="$command --zone $zone"
command="$command --license-type $licenseType"

# Execute the command
echo .
echo -----------
echo " -> Creating VM"
echo .
echo $command
echo .
eval $command
#output=$(eval $command)
#provisioningState=$(echo "$output" | jq -r '.privateIpAddress')
#if [ -n "$provisioningState" ]; then
#    echo "IP Address $provisioningState"
#else
#    echo "Provisioning not succeeded"
#    echo "$output" | jq -r
#    exit 1
#fi

echo .
# Boot Diagnostics
echo " -> Enabling VM Diagnostics"
az vm boot-diagnostics enable --resource-group $destinationResourceGroup --subscription $destinationSubscription --name $vmName
echo "Complete."
