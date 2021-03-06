#!/bin/bash
# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# This script is called by the other install scripts to layout the crowbar
# software + pieces.
#
# Requires:
# /tftpboot/redhat_dvd is populated with appropriate files.
#

cat <<EOF >/etc/sysconfig/network-scripts/ifcfg-eth0
DEVICE=eth0
BOOTPROTO=none
ONBOOT=yes
NETMASK=255.255.255.0
IPADDR=192.168.124.10
GATEWAY=192.168.124.1
TYPE=Ethernet
EOF

(cd /etc/yum.repos.d && rm *)

(   mkdir -p "/tftpboot/$OS_TOKEN"
    cd "/tftpboot/$OS_TOKEN"
    ln -s ../redhat_dvd install)

REPO_URL="file:///tftpboot/$OS_TOKEN/install/Server"
[[ -d tftpboot/$OS_TOKEN/install/repodata ]] && \
    REPO_URL="file:///tftpboot/$OS_TOKEN/install"

cat >"/etc/yum.repos.d/$OS_TOKEN-Base.repo" <<EOF
[$OS_TOKEN-Base]
name=$OS_TOKEN Base
baseurl=$REPO_URL
gpgcheck=0
EOF

# Barclamp preparation (put them in the right places)
mkdir -p /opt/dell/barclamps
for i in "$BASEDIR/dell/barclamps/"*".tar.gz"; do
    [[ -f $i ]] || continue
    ( cd "/opt/dell/barclamps"; tar xzf "$i"; )
done


find /opt/dell/barclamps -type d -name cache -maxdepth 2 | while read src; do
    [[ -d $src/$OS_TOKEN/pkgs/repodata ]] || continue
    bc=${src%/cache}
    bc=${bc##*/}
   cat >"/etc/yum.repos.d/crowbar-$bc.repo" <<EOF
[crowbar-$bc]
name=Crowbar $bc Packages
baseurl=file://$src/$OS_TOKEN/pkgs
gpgcheck=0
EOF
done

# Make sure we only try to install x86_64 packages.
echo 'exclude = *.i?86' >>/etc/yum.conf
# Nuke any non-64 bit packages that snuck in.
yum -y erase '*.i?86'
yum -y makecache

yum -y install createrepo

for bc in "$BASEDIR/dell/barclamps/"*.rpm; do
    [[ -f $bc ]] || continue
    mkdir -p /opt/dell/rpms
    cp "$bc" /opt/dell/rpms
done
if [[ -d /opt/dell/rpms ]]; then
    (cd /opt/dell/rpms; createrepo -d -q .)
    cat >"/etc/yum.repos.d/crowbar.repo" <<EOF
[crowbar]
name=Crowbar Packages
baseurl=file:///opt/dell/rpms
gpgcheck=0
EOF
fi

# for CentOS.
(cd "$BASEDIR"; [[ -d Server ]] || ln -sf . Server)

# We prefer rsyslog.
yum -y install rsyslog
chkconfig syslog off
chkconfig rsyslog on

# Make sure rsyslog picks up our stuff
echo '$IncludeConfig /etc/rsyslog.d/*.conf' >>/etc/rsyslog.conf
mkdir -p /etc/rsyslog.d/

# Make runlevel 3 the default
sed -i -e '/^id/ s/5/3/' /etc/inittab

# Make sure /opt is created
mkdir -p /opt/dell/bin

# Make a destination for dell finishing scripts

finishing_scripts=(update_hostname.sh parse_node_data)
( cd "$BASEDIR/dell"; cp "${finishing_scripts[@]}" /opt/dell/bin; )

# "Install h2n for named management"
cd /opt/dell/
tar -zxf "$BASEDIR/extra/h2n.tar.gz"
ln -s /opt/dell/h2n-2.56/h2n /opt/dell/bin/h2n

# put the chef files in place
cp "$BASEDIR/rsyslog.d/"* /etc/rsyslog.d/

barclamp_scripts=(barclamp_install.rb barclamp_multi.rb)
( cd "/opt/dell/barclamps/crowbar/bin" &&  \
    cp "${barclamp_scripts[@]}" /opt/dell/bin || :)

# Make sure the bin directory is executable
chmod +x /opt/dell/bin/*

# Make sure we can actaully install Crowbar
chmod +x "$BASEDIR/extra/"*

# This directory is the model to help users create new barclamps
cp -r /opt/dell/barclamps/crowbar/crowbar_framework/barclamp_model /opt/dell || :

# "Blacklisting IPv6".
echo "blacklist ipv6" >>/etc/modprobe.d/blacklist-ipv6.conf
echo "options ipv6 disable=1" >>/etc/modprobe.d/blacklist-ipv6.conf

# Make sure the ownerships are correct
chown -R crowbar.admin /opt/dell

# Look for any crowbar specific kernel parameters
for s in $(cat /proc/cmdline); do
    VAL=${s#*=} # everything after the first =
    case ${s%%=*} in # everything before the first =
        crowbar.hostname) CHOSTNAME=$VAL;;
        crowbar.url) CURL=$VAL;;
        crowbar.use_serial_console)
            sed -i "s/\"use_serial_console\": .*,/\"use_serial_console\": $VAL,/" /opt/dell/chef/data_bags/crowbar/bc-template-provisioner.json;;
        crowbar.debug.logdest)
            echo "*.*    $VAL" >> /etc/rsyslog.d/00-crowbar-debug.conf
            mkdir -p "$BASEDIR/rsyslog.d"
            echo "*.*    $VAL" >> "$BASEDIR/rsyslog.d/00-crowbar-debug.conf"
            ;;
        crowbar.authkey)
            mkdir -p "/root/.ssh"
            printf "$VAL\n" >>/root/.ssh/authorized_keys
            printf "$VAL\n" >>/opt/dell/barclamps/provisioner/chef/cookbooks/provisioner/templates/default/authorized_keys.erb
            ;;
        crowbar.debug)
            sed -i -e '/config.log_level/ s/^#//' \
                -e '/config.logger.level/ s/^#//' \
                /opt/dell/barclamps/crowbar/crowbar_framework/config/environments/production.rb
            ;;
    esac
done

ln -s /tftpboot/redhat_dvd/extra/install /opt/dell/bin/install-crowbar
