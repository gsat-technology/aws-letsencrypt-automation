# aws-letsencrypt-automation

Let’s Encrypt is a free, automated, and open certificate authority which allows you to automate the provisioning of SSL certificates.

Solves this problem: You have a Route53 hosted zone and domain e.g. `mydomain.com` and you want to obtain a certificate for `subdomain.mydomain.com`

*NOTE: ACM (AWS Certificate Manager) now largely solves this problem for CloudFront and ELBs but you could still want to obtain a certificate for other purposes*

The manual way of solving this problem is:

- launch an EC2 instance
- point the Route53 record at the EC2 instance's public IP address
- install the Letsencrypt tool
- run the tool 
- download the SSL certificate from the instance
- destroy the EC2 instance

This CloudFormation template automates this by:

- launching an EC2 instance
- using EC2 user data to install and run the Letsencrypt tool
- uploading certificate directly to IAM *OR* exporting certificate to nominated S3 bucket 
- self-destroying the stack

###Launching the Stack

1. Create new CloudFormation stack
2. Upload `cloudformation-letsencrypt.json` 
3. Complete parameters form

######AutoDelete: true | false

When set to `true`, the resulting SSL certificates will be uploaded to IAM via API call. The EC2 instance will issue an API call to CloudFormation to destroy the stack.

When set to `false` the certificates will be zipped up and PUT into the nominated S3 bucket. All stack resources will remain running and you will need to tear the stack down after retrieving the certificates from S3.

######AvailabilityZone:
Choose an AZ from the drop-down list

######Domain:
The FQDN you want an SSL certificate for

######HostedZoneId:
Choose your Route53 hosted zone ID from the drop-down list

######KeyName:
Choose an existing EC2 keypair from the drop-down

######S3BucketName
S3 bucket that will be created to store the SSL certificates after they've been created

######VPC
Choose a VPC from the drop down list


###Troubleshooting

Check `/var/log/cloud-init-output.log` on EC2 instance 

