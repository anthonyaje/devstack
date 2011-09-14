#!/bin/bash
# Configurable params
BRIDGE=${BRIDGE:-br0}
CONTAINER=${CONTAINER:-STACK}
CONTAINER_IP=${CONTAINER_IP:-192.168.1.50}
CONTAINER_CIDR=${CONTAINER_CIDR:-$CONTAINER_IP/24}
CONTAINER_NETMASK=${CONTAINER_NETMASK:-255.255.255.0}
CONTAINER_GATEWAY=${CONTAINER_GATEWAY:-192.168.1.1}
NAMESERVER=${NAMESERVER:-192.168.1.1}
COPYENV=${COPYENV:-1}

# Create lxc configuration
LXC_CONF=/tmp/$CONTAINER.conf
cat > $LXC_CONF <<EOF
lxc.network.type = veth
lxc.network.link = $BRIDGE
lxc.network.flags = up
lxc.network.ipv4 = $CONTAINER_CIDR
# allow tap/tun devices
lxc.cgroup.devices.allow = c 10:200 rwm
EOF

# Shutdown any existing container
lxc-stop -n $CONTAINER

# This prevents zombie containers
cgdelete -r cpu,net_cls:$CONTAINER

# Warm the base image on first install
CACHEDIR=/var/cache/lxc/natty/rootfs-amd64
if [ ! -d $CACHEDIR ]; then
    # trigger the initial debootstrap
    lxc-create -n $CONTAINER -t natty -f $LXC_CONF
    chroot $CACHEDIR apt-get update
    chroot $CACHEDIR apt-get install -y `cat apts/* | cut -d\# -f1 | egrep -v "(rabbitmq|libvirt-bin|mysql-server)"`
    chroot $CACHEDIR pip install `cat pips/*`
fi

# Destroy the old container
lxc-destroy -n $CONTAINER

# Create the container
lxc-create -n $CONTAINER -t natty -f $LXC_CONF

# Specify where our container rootfs lives
ROOTFS=/var/lib/lxc/$CONTAINER/rootfs/

# Create a stack user that is a member of the libvirtd group so that stack 
# is able to interact with libvirt.
chroot $ROOTFS groupadd libvirtd
chroot $ROOTFS useradd stack -s /bin/bash -d /opt -G libvirtd

# a simple password - pass
echo stack:pass | chroot $ROOTFS chpasswd

# and has sudo ability (in the future this should be limited to only what 
# stack requires)
echo "stack ALL=(ALL) NOPASSWD: ALL" >> $ROOTFS/etc/sudoers

# Copy over your ssh keys and env if desired
if [ "$COPYENV" = "1" ]; then
    cp -pr ~/.ssh $ROOTFS/opt/.ssh
    cp -p ~/.ssh/id_rsa.pub $ROOTFS/opt/.ssh/authorized_keys
    cp -pr ~/.gitconfig $ROOTFS/opt/.gitconfig
    cp -pr ~/.vimrc $ROOTFS/opt/.vimrc
    cp -pr ~/.bashrc $ROOTFS/opt/.bashrc
fi

# Give stack ownership over /opt so it may do the work needed
chroot $ROOTFS chown -R stack /opt

# Configure instance network
INTERFACES=$ROOTFS/etc/network/interfaces
cat > $INTERFACES <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
        address $CONTAINER_IP
        netmask $CONTAINER_NETMASK
        gateway $CONTAINER_GATEWAY
EOF

# Configure the first run installer
INSTALL_SH=$ROOTFS/root/install.sh
cat > $INSTALL_SH <<EOF
#!/bin/bash
# Disable startup script
echo \#\!/bin/sh -e > /etc/rc.local
# Make sure dns is set up
echo "nameserver $NAMESERVER" | resolvconf -a eth0
sleep 1

# Install and run stack.sh
apt-get update
apt-get -y --force-yes install git-core vim-nox sudo
su -c "git clone git://github.com/cloudbuilders/nfs-stack.git ~/nfs-stack" stack
su -c "cd ~/nfs-stack && ./stack.sh" stack
EOF

# Make the install.sh executable
chmod 700 $INSTALL_SH

# Make installer run on boot
RC_LOCAL=$ROOTFS/etc/rc.local
cat > $RC_LOCAL <<EOF
#!/bin/sh -e
/root/install.sh
EOF

# Configure cgroup directory
mkdir -p /cgroup
mount none -t cgroup /cgroup

# Start our container
lxc-start -d -n $CONTAINER
