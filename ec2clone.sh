#!/bin/bash

##########################################################
# This script creates an AMI from an existing EC2 instance
# and creates a new EC2 instance from the AMI.
# Developed by costa@3s.money
##########################################################

# Execution argument check
# Check if an argument is provided
if [ -z "$1" ]; then
    echo "No instance ID provided. Usage: ec2clone.sh instance-id ClonedInstanceName"
    exit 1
fi

if [ -z "$2" ]; then
    echo "No New Cloned Instance name provided. Usage: ec2clone.sh instance-id ClonedInstanceName"
    exit 1
fi


# Pre-requisities check. 
# Delete or comment this section if update/installation is not needed.

# Function to check if a command is installed
is_installed() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to install a package
install_package() {
    if apt install "$1" -y; then
        echo "Successfully installed $1 without sudo."
    elif sudo apt install "$1" -y; then
        echo "Successfully installed $1 with sudo."
    else
        echo "Failed to install $1."
        exit 1
    fi
}

# Check and install awscli
if is_installed "aws"; then
    echo "awscli is already installed."
else
    echo "awscli is not installed. Attempting to install..."
    install_package "awscli"
fi

# Check and install jq
if is_installed "jq"; then
    echo "jq is already installed."
else
    echo "jq is not installed. Attempting to install..."
    install_package "jq"
fi

##########################################################
# Check if AWS is configured 
# If not, run 'aws configure' to configure it
# Delete this section if configuration is not needed.
##########################################################

CONFIG_FILE="$HOME/.aws/config"
CREDENTIALS_FILE="$HOME/.aws/credentials"

# Function to check if AWS CLI is configured
is_aws_configured() {
    if [[ -s $CONFIG_FILE ]] && [[ -s $CREDENTIALS_FILE ]]; then
        return 0
    else
        return 1
    fi
}

# Main script execution
if is_aws_configured; then
    echo "AWS CLI is already configured."
else
    echo "AWS CLI is not configured. Running 'aws configure'..."
    aws configure
fi


##########################################################
#
# Script starts here
#
##########################################################

# Taking the ID of the EC2 instance from variable
id=$1  # Replace with hardcoded ID if you need to

# Storing the description of the EC2 instance in a variable
instance_description=$(aws ec2 describe-instances --instance-ids $id)

echo "Instance description:"
echo "**********************************************"
echo $instance_description
echo "**********************************************"

# Reading the block devices and volumes of the instance
dev_list=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].DeviceName')
vol_list=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId')

# Converting the lists into arrays
devs=($dev_list)
vols=($vol_list)

echo "dev vols:"
echo "**********************************************"
echo $devs
echo $vols
echo "**********************************************"


# Reading other instance details
instance_type=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].InstanceType')
region=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].Placement.AvailabilityZone' | sed 's/[a-z]$//')
kernel=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].KernelId')
security_group=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId')
key=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].KeyName')
subnet_id=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].SubnetId')
architecture=$(echo "$instance_description" | jq -r '.Reservations[].Instances[].Architecture')

# Displaying the instance features
echo "**********************************************"
echo "Instance features:"
echo ""
echo "Block devices: ${devs[@]}"
echo "Volumes: ${vols[@]}"
echo "Instance type: $instance_type"
echo "Region: $region"
echo "Kernel ID: $kernel"
echo "Security group: $security_group"
echo "Key pair name: $key"
echo "**********************************************"

# Displaying the volumes with their features
echo ""
echo "Volumes found:"
j=0  # Index for the volumes array
snapshot_name=$2 # Replace with hardcoded name if you need to

for vol in "${vols[@]}"; do
    # Reading the volume features
    volumes=$(aws ec2 describe-volumes --volume-ids $vol)

    vol_sizes[$j]=$(echo "$volumes" | jq -r '.Volumes[].Size')
    vol_types[$j]=$(echo "$volumes" | jq -r '.Volumes[].VolumeType')
    vol_dels[$j]=$(echo "$volumes" | jq -r '.Volumes[].Attachments[].DeleteOnTermination')

    # Displaying the volume features
    echo ""
    echo "Volume id: $vol"
    echo "Size: ${vol_sizes[$j]}"
    echo "Type: ${vol_types[$j]}"
    echo "Delete on instance termination: ${vol_dels[$j]}"

    # Creating a snapshot for each volume
    snapshots[$j]=$(aws ec2 create-snapshot --volume-id $vol --query 'SnapshotId' --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$snapshot_name}]" --output text)
   ((++j))
done

# Waiting until all snapshots have been built
echo "**********************************************"
echo ""
echo "Checking the status of the snapshots"
echo "SNAPSHOT ID ##################################"
echo $snapshots
echo "**********************************************"

for snapshot in "${snapshots[@]}"; do
    status=''
    until [ "$status" = "completed" ]; do
        status=$(aws ec2 describe-snapshots --snapshot-ids $snapshot --query 'Snapshots[].State' --output text)
        echo "Snapshot: $snapshot Status: $status"
        sleep 5
    done
done

# Registering the AMI
ami_name="${2}_$(date +"%y%m%d_%H%M%S")" # Replace with hardcoded name if you need to
echo "Registering the AMI: $ami_name" 
ami=$(aws ec2 register-image --name $ami_name --root-device-name /dev/sda1 --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=snap-06c60e9c64d73ea75}" --query 'ImageId' --output text)

# Creating the EC2 instance
echo "Creating the EC2 instance"
instance=$(aws ec2 run-instances --image-id $ami --count 1 --instance-type $instance_type --key-name $key --subnet-id $subnet_id --security-group-ids $security_group --region $region --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$ami_name}]")

# Reading the ID of the new instance
new_id=$(echo $instance | jq -r '.Instances[].InstanceId')

# Waiting until the instance is running
until [[ "$status" = *"running"* ]]; do
    status=$(aws ec2 describe-instances --instance-ids $new_id --query 'Reservations[].Instances[].State.Name' --output text)
    echo ""
    echo "Instance status: $status"
    sleep 5
done

# Reading the public IP address
ip=$(aws ec2 describe-instances --instance-ids $new_id --query 'Reservations[].Instances[].PublicIpAddress' --output text)
echo ""
echo "Instance IP address: $ip"
