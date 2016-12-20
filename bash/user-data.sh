#!/bin/bash

REGION=
EMAIL=
DOMAIN=
S3_BUCKET=
CERTS_PATH=/etc/letsencrypt/archive/$DOMAIN/

apt-get update
apt-get install -y apache2
apt-get install -y git
apt-get install -y awscli

git clone https://github.com/letsencrypt/letsencrypt /opt/letsencrypt

cat >/cli.ini <<EOF
email=$EMAIL
agree-tos=True
text=True
EOF

#input '1' as answer to interactive question
cat >interactive.txt <<EOF
1
EOF

#use letsencrypt client to create the certificate
./opt/letsencrypt/letsencrypt-auto --config /cli.ini --apache -d $DOMAIN < interactive.txt

#tar and gzip them up
(cd $CERTS_PATH ; tar -zcvf $DOMAIN.tar.gz . )

#cp to S3
aws s3 --region $REGION cp $CERTS_PATH$DOMAIN.tar.gz s3://$S3_BUCKET



