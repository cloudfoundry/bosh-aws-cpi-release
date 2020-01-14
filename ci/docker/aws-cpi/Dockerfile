FROM ubuntu:xenial

RUN apt-get clean && apt-get update && apt-get install -y locales

ENV LANG en_US.UTF-8
ENV LC_ALL en_US.UTF-8
RUN locale-gen en_US.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    git curl wget tar make unzip \
    sqlite3 libsqlite3-dev \
    mysql-client libmysqlclient-dev \
    libpq-dev \
    jq \
    python python-pip realpath && \
    apt-get clean

RUN pip install --upgrade pip
RUN pip install -U setuptools
RUN pip install awscli

ENV RUBY_INSTALL_VERSION=0.7.0 RUBY_VERSION=2.6.5

# Install ruby-install
RUN cd /tmp && \
    wget -nv -O ruby-install-$RUBY_INSTALL_VERSION.tar.gz https://github.com/postmodern/ruby-install/archive/v$RUBY_INSTALL_VERSION.tar.gz && \
    wget -nv https://raw.github.com/postmodern/ruby-install/master/pkg/ruby-install-$RUBY_INSTALL_VERSION.tar.gz.asc && \
    tar -xzvf ruby-install-$RUBY_INSTALL_VERSION.tar.gz && \
    cd ruby-install-$RUBY_INSTALL_VERSION/ && \
    make install && \
    rm -rf /tmp/ruby-install-$RUBY_INSTALL_VERSION && rm /tmp/*

# Install Ruby
RUN ruby-install --jobs=2 --cleanup --system ruby "$RUBY_VERSION" -- --disable-install-rdoc

RUN ruby -v && gem update --system
