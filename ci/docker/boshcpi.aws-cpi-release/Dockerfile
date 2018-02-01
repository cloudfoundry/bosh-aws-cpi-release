FROM ubuntu:14.04

RUN locale-gen en_US.UTF-8
RUN dpkg-reconfigure locales
ENV LANG en_US.UTF-8
ENV LC_ALL en_US.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git curl wget tar make unzip \
    sqlite3 libsqlite3-dev \
    mysql-client libmysqlclient-dev \
    libpq-dev \
    python python-pip realpath && \
    apt-get clean && \
    pip install awscli

ENV RUBY_INSTALL_VERSION=0.6.1 CHRUBY_VERSION=0.3.9 RUBY_VERSION=2.4.2 JQ_VERSION=1.5

# Import stedolan PGP key (jq)
RUN wget -nv https://raw.githubusercontent.com/stedolan/jq/master/sig/jq-release.key && \
    gpg --import jq-release.key && \
    gpg --fingerprint 0x71523402 | grep 'Key fingerprint = 4FD7 01D6 FA9B 3D2D F5AC  935D AF19 040C 7152 3402' && \
    if [ "$?" != "0" ]; then echo "Invalid PGP key!"; exit 1; fi

# Install jq
RUN cd /tmp && \
    wget -nv https://github.com/stedolan/jq/releases/download/jq-$JQ_VERSION/jq-linux64 && \
    wget -nv https://raw.githubusercontent.com/stedolan/jq/master/sig/v$JQ_VERSION/jq-linux64.asc && \
    gpg --verify jq-linux64.asc jq-linux64 && \
    chmod +x jq-linux64 && \
    mv jq-linux64 /usr/local/bin/jq

# Import Postmodern PGP key
RUN wget -nv https://raw.github.com/postmodern/postmodern.github.io/master/postmodern.asc && \
    gpg --import postmodern.asc && \
    gpg --fingerprint 0xB9515E77 | grep 'Key fingerprint = 04B2 F3EA 6541 40BC C7DA  1B57 54C3 D9E9 B951 5E77' && \
    if [ "$?" != "0" ]; then echo "Invalid PGP key!"; exit 1; fi

# Install chruby
RUN cd /tmp && \
    wget -nv -O chruby-$CHRUBY_VERSION.tar.gz https://github.com/postmodern/chruby/archive/v$CHRUBY_VERSION.tar.gz && \
    wget -nv https://raw.github.com/postmodern/chruby/master/pkg/chruby-$CHRUBY_VERSION.tar.gz.asc && \
    gpg --verify chruby-$CHRUBY_VERSION.tar.gz.asc chruby-$CHRUBY_VERSION.tar.gz && \
    tar -xzvf chruby-$CHRUBY_VERSION.tar.gz && \
    cd chruby-$CHRUBY_VERSION/ && \
    sudo ./scripts/setup.sh && \
    rm -rf /tmp/chruby-$CHRUBY_VERSION && rm /tmp/*

# Install ruby-install
RUN cd /tmp && \
    wget -nv -O ruby-install-$RUBY_INSTALL_VERSION.tar.gz https://github.com/postmodern/ruby-install/archive/v$RUBY_INSTALL_VERSION.tar.gz && \
    wget -nv https://raw.github.com/postmodern/ruby-install/master/pkg/ruby-install-$RUBY_INSTALL_VERSION.tar.gz.asc && \
    gpg --verify ruby-install-$RUBY_INSTALL_VERSION.tar.gz.asc ruby-install-$RUBY_INSTALL_VERSION.tar.gz && \
    tar -xzvf ruby-install-$RUBY_INSTALL_VERSION.tar.gz && \
    cd ruby-install-$RUBY_INSTALL_VERSION/ && \
    sudo make install && \
    rm -rf /tmp/ruby-install-$RUBY_INSTALL_VERSION && rm /tmp/*

# Install Ruby
RUN apt-get update && ruby-install ruby $RUBY_VERSION -- --disable-install-rdoc

# Install Bundler
RUN /bin/bash -l -c "               \
  source /etc/profile.d/chruby.sh ; \
  chruby $RUBY_VERSION ;            \
  gem install --no-document bundler \
"
