#!/bin/bash

#User-defined variables
REGION=ap-southeast-2 
HOSTED_ZONE_ID=<route 53 hosted zone id>  
S3_BUCKET="<your s3 bucket name>"
DOMAIN="<domain for ssl cert>"
EMAIL="<email address attached to cert>"

#EC2
KEYPAIR=letsencrypt-keypair
SEC_GROUP=letsencrypt-sg
IMAGE_ID=ami-6c14310f #Ubuntu 14.04
NAME_TAG=letsencrypt-bash-script
USER_DATA=./user-data.sh

#IAM
ROLE_NAME=letsencrypt-role
POLICY_NAME=$ROLE_NAME-policy
ROLE_POLICY_DOC=./role-policy-doc.json
POLICY_DOC=./policy-doc.json

#Route53
CHANGE_BATCH=./change_batch.json


#Creates and configures the AWS resources
create_resources()
{
  #create S3 bucket
  aws s3 mb --region $REGION s3://$S3_BUCKET
 
    
  #IAM
  cat >$ROLE_POLICY_DOC <<EOF
{
    "Version": "2012-10-17",
    "Statement": [  
        {
	      "Effect": "Allow",
	      "Principal": {
  		"Service": "ec2.amazonaws.com"
	      },
	      "Action": "sts:AssumeRole"
	}
    ]
}
EOF

cat >$POLICY_DOC <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
	{
	    "Effect": "Allow",
	    "Action": [
		"s3:PutObject"
	    ],
	    "Resource": [
		"arn:aws:s3:::$S3_BUCKET/*"
	    ]
	}
    ]
}
EOF

#create the role that will be used by the ec2 instance
echo "creating role"
instance_role_arn=$(aws iam create-role --role-name $ROLE_NAME \
                                        --assume-role-policy-document file://$ROLE_POLICY_DOC \
			                --output text \
		                        --query Role.Arn)

echo "putting policy"
aws iam put-role-policy --role-name $ROLE_NAME \
		        --policy-name $POLICY_NAME \
		        --policy-document file://$POLICY_DOC

#clean up the temporary files
rm $ROLE_POLICY_DOC			
rm $POLICY_DOC


#this is what automatically happens in the console
echo "creating instance profile $ROLE_NAME"
aws iam create-instance-profile --instance-profile-name $ROLE_NAME

echo "adding $ROLE_NAME role to instance profile $ROLE_NAME"
aws iam add-role-to-instance-profile --instance-profile-name $ROLE_NAME \
                                     --role-name $ROLE_NAME

#wait for role to be added to instance profile
echo -n "waiting for role to be added to profile..."
while [ 1 -eq 1 ];
do
    aws iam get-instance-profile --instance-profile-name $ROLE_NAME | grep AssumeRolePolicyDocument 2>&1
    
    if [ $? -eq 0 ];
    then
	echo "role has been added to profile"
	sleep 3
	break
    fi

    echo -n "."
    sleep 3
done



###EC2
aws ec2 create-key-pair --key-name $KEYPAIR

vpc_id=$(aws ec2 describe-vpcs --output text \
	                       --query 'Vpcs[?IsDefault == `true`] | [0].VpcId')

echo "default vpc id: $vpc_id"

subnet_id=$(aws ec2 describe-subnets --filter Name=vpc-id,Values=$vpc_id \
		                     --output text \
		                     --query 'Subnets[?DefaultForAz == `true`] | [0].SubnetId')

echo "subnet id: $subnet_id"


#craete a security group associated with the default vpc
sec_id=$(aws ec2 create-security-group --group-name $SEC_GROUP \
	                               --description 'temporary sec group' \
               	                       --vpc-id $vpc_id \
				       --output text \
	                               --query GroupId)

echo "created security group with id: $sec_id"

echo "authorising security group ingress on port 80"
aws ec2 authorize-security-group-ingress --group-id $sec_id \
                                         --protocol tcp --port 80 --cidr 0.0.0.0/0

echo "authorising security group ingress on port 443"
aws ec2 authorize-security-group-ingress --group-id $sec_id \
                                         --protocol tcp --port 443 --cidr 0.0.0.0/0

cp $USER_DATA ./user-data-copy.sh
#use sed to edit values in the user-data.sh file before creating instance
sed -i '' "s/S3_BUCKET=/S3_BUCKET=$S3_BUCKET/" ./user-data-copy.sh
sed -i '' "s/REGION=/REGION=$REGION/" ./user-data-copy.sh
sed -i '' "s/EMAIL=/EMAIL=$EMAIL/" ./user-data-copy.sh
sed -i '' "s/DOMAIN=/DOMAIN=$DOMAIN/g" ./user-data-copy.sh


echo "creating ec2 instance"
instance_id=$(aws ec2 run-instances --image-id $IMAGE_ID \
		                    --count 1 \
		                    --instance-type t2.micro \
		                    --key-name george-aws-wordpress \
				    --security-group-ids $sec_id \
				    --subnet-id $subnet_id \
				    --associate-public-ip-address \
				    --user-data file://./user-data-copy.sh \
				    --iam-instance-profile Name=$ROLE_NAME \
				    --output text \
				    --query Instances[0].InstanceId)

echo "instance started with id: $instance_id"

#tag the instance so it can be easily identified
aws ec2 create-tags --resources $instance_id --tags Key=Name,Value=$NAME_TAG


echo "getting public ip"
public_ip=$(aws ec2 describe-instances --instance-ids $instance_id \
		                       --output text \
                        	       --query Reservations[0].Instances[0].PublicIpAddress)

echo "public ip for instance: $public_ip"

#create a local file for the route53 record set
cat >$CHANGE_BATCH <<EOF
{
    "Comment": "this is a comment",
    "Changes": [
	{
	    "Action": "CREATE",
	    "ResourceRecordSet": {
		"Name": "$DOMAIN",
		"Type":"A",
		"TTL": 300,
		"ResourceRecords": [
		    {
			"Value": "$public_ip"
		    }
		]
	    }
	}

    ]
}
EOF


#create the record set for the domain
aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch file://$CHANGE_BATCH


} #End create_resources()


#Tears down the AWS resources
remove_resources()
{

  #get some details of the ec2 instance. Filters for running instances with name tag
  echo "getting ec2 instance details"  
  result=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running Name=tag:Name,Values=$NAME_TAG \
	                              --max-items 1 \
		                      --output text \
		                      --query 'Reservations[].Instances[] | [0] | {"public_ip": PublicIpAddress, "instance_id": InstanceId}')

  
  instance_id=$(echo $result | awk '{print $1;}')  
  public_ip=$(echo $result | awk '{print $2;}')

  echo "retrieved instance id: $instance_id"
  echo "retrieved public ip: $public_ip"
  
  #Remove Route53 resources
  cat >$CHANGE_BATCH <<EOF
{
    "Comment": "this is a comment",
    "Changes": [
       {
        "Action": "DELETE",
        "ResourceRecordSet": {
    	    "Name": "$DOMAIN",
	    "Type":"A",
	    "TTL": 300,
	    "ResourceRecords": [
	        {
	    	    "Value": "$public_ip"
	        }
	      ]
           }
       }
    ] 
}
EOF

  #remove the route53 record
  echo "deleting route 53 record for $DOMAIN with ip: $public_ip"
  aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
                                        --change-batch file://$CHANGE_BATCH

  #remove ec2 keypair
  echo "deleting keypair: $KEYPAIR"
  aws ec2 delete-key-pair --key-name $KEYPAIR


  #remove role from instance profile
  echo "removing $ROLE_NAME from instance profile $ROLE_NAME"
  aws iam remove-role-from-instance-profile --instance-profile-name $ROLE_NAME \
                                            --role-name $ROLE_NAME

  #remove instance profile
  echo "deleting instance profile $ROLE_NAME"
  aws iam delete-instance-profile --instance-profile-name $ROLE_NAME

  #delete role policy
  echo "deleting policy $POLICY_NAME from role $ROLE_NAME"
  aws iam delete-role-policy --role-name $ROLE_NAME \
                             --policy-name $POLICY_NAME

  #delete role
  echo "deleting role $ROLE_NAME"
  aws iam delete-role --role-name $ROLE_NAME

  #remove the ec2 instance
  echo "terminating instance with instance id: $instance_id"
  aws ec2 terminate-instances --instance-ids $instance_id
  
 
  echo -n "need to wait for ec2 instance to be terminated before attempting to delete security group..."
  while [ 1 -eq 1 ];
  do
    result=$(aws ec2 describe-instances --instance-ids $instance_id \
	                                --filters Name=tag:Name,Values=$NAME_TAG \
	                                --output text \
			                --query Reservations[0].Instances[0].State.Name)
    
    if [ "$result" == "terminated" ];
    then
	echo "instance has been terminated"
	break
    fi

    echo -n "."
    sleep 3
done

  #remove the ec2 security group
  echo "deleting security group $SEC_GROUP"
  aws ec2 delete-security-group --group-name $SEC_GROUP
  
  #remove s3 bucket
  aws s3 rb s3://$S3_BUCKET --force
  echo "finished removing resources"
} #End remove_resources()



case "$1" in

    create)
	create_resources
	exit 0
	;;
    remove)
	remove_resources
	exit 0
	;;
    *)
	echo "Usage: supply 'create' or 'remove'"
	exit 0
	;;
esac
