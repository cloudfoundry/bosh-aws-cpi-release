FROM ubuntu:15.04

RUN locale-gen en_US.UTF-8
RUN dpkg-reconfigure locales
ENV LANG en_US.UTF-8
ENV LC_ALL en_US.UTF-8

RUN apt-get update; apt-get -y upgrade; apt-get clean

RUN apt-get install -y git curl wget tar make unzip; apt-get clean

RUN apt-get install -y libxslt-dev libxml2-dev zlib1g-dev; apt-get clean;

RUN apt-get install -y vagrant; apt-get clean; vagrant plugin install vagrant-aws

RUN apt-get install -y python python-pip groff jq; apt-get clean; pip install awscli;
