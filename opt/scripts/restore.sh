#!/bin/sh


opkg update

cat user_packages | xargs opkg install

chmod +x pia_vpn_manager.sh setup_native_double_vpn.sh

sh setup_native_double_vpn.sh



echo "Wait for network to change ip and then reconnect to 192.168.2.1"
echo "Run: sh pia_vpn_manager.sh configure"
echo "Then Run: sh pia_vpn_manager.sh start"