#!/bin/bash
##
# Copyright (C) 2013-2016 Janek Bevendorff
# Website: http://www.refining-linux.org/
# 
# Install script for installing server and client script files
# 
# The MIT License (MIT)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
##

if [[ "$1" != "all" ]] && [[ "$1" != "client" ]] && [[ "$1" != "server" ]]; then
	./server/usr/bin/rs-version headline "rs-backup-suite installer"
	./server/usr/bin/rs-version copyright
	echo
	echo "Usage: $(basename $0) [all|server|client]"
	exit
fi

if [ $(id -u) -ne 0 ] && [[ "$(uname -o)" != "Cygwin" ]]; then
	echo "ERROR: This script must be run as root."
	exit 1
fi


###############################################################################
# Global variables
###############################################################################
DISTRIBUTION="$(./server/usr/bin/rs-detect-distribution)"
COMPONENT="$1"
MODE="install"
if [[ "$(basename $0)" == "uninstall.sh" ]]; then
	MODE="uninstall"
fi


###############################################################################
# Command aliases
###############################################################################
CP="cp -vr --preserve=mode,timestamps,links"
RM="rm -Rvf"
MKDIR="mkdir -pv"


###############################################################################
# Install mode
###############################################################################
if [[ $MODE == "install" ]]; then

	# Server component
	if [[ $COMPONENT == "all" ]] || [[ $COMPONENT == "server" ]]; then
		echo "Installing Server component..."

		$CP ./server/usr/bin/*     /usr/bin/
		$CP ./server/usr/sbin/*    /usr/sbin/
		$CP ./server/etc/rs-skel   /etc/
		
		# Do not overwrite existing config
		if [ ! -e /etc/rs-backup/server-config ]; then
			$CP ./server/etc/rs-backup /etc/
		fi

		echo
		echo "Installing cron scripts..."
		if [ -d /etc/cron.daily ]; then
			$CP ./server/etc/cron.daily/* /etc/cron.daily/
			$CP ./server/etc/cron.weekly/* /etc/cron.weekly/
			$CP ./server/etc/cron.monthly/* /etc/cron.monthly/
		elif [ -e /etc/crontab ]; then
			if ! grep -q "/usr/sbin/rs-rotate-cron" /etc/crontab; then
				if [[ "$DISTRIBUTION" == "Synology" ]]; then
					cat ./server/etc/crontab_synology >> /etc/crontab
					synoservicectl --reload crond
				else
					cat ./server/etc/crontab >> /etc/crontab
				fi
			fi
		else
			echo "ERROR: Could not install cron scripts, please add rotation jobs manually." >&2
		fi

		echo
		echo "Installing backup directory..."
		if [ -e /etc/rs-backup/server-config ]; then
			BKP_DIR="$(grep -o '^BACKUP_ROOT=".*"$' /etc/rs-backup/server-config | sed 's#BACKUP_ROOT=\"\(.*\)\"$#\1#')"
		else
			BKP_DIR="/bkp"
		fi
		if [[ "$DISTRIBUTION" == "Synology" ]] && [[ "$BKP_DIR" == "/bkp" ]]; then
			if readlink -q /var/services/homes > /dev/null; then
				BKP_DIR="/var/services/homes"
			elif [ -d /volume1/homes ]; then
				# Try hard
				BKP_DIR="/volume1/homes"
			fi
		fi

		echo "Backup directory path will be '$BKP_DIR'."
		echo -n "Do you want to use this directory? [Y/n] "
		read answer

		if [[ "" != "$answer" ]] && [[ "Y" != "$answer" ]] && [[ "y" != "$answer" ]]; then
			echo -n "Please enter a new location: "
			read BKP_DIR
		fi

		# Correct backup folder path in server config
		sed -i "s#^BACKUP_ROOT=\".*\"\$#BACKUP_ROOT=\"$BKP_DIR\"#" /etc/rs-backup/server-config

		echo "Creating backup directory structure at '$BKP_DIR'..."

		$MKDIR "$BKP_DIR"/bin
		$MKDIR "$BKP_DIR"/dev
		$MKDIR "$BKP_DIR"/etc
		$MKDIR "$BKP_DIR"/lib
		$MKDIR "$BKP_DIR"/usr/bin
		[[ "$DISTRIBUTION" != "Synology" ]] && $MKDIR "$BKP_DIR"/usr/lib

		if [[ "$DISTRIBUTION" == "Ubuntu" ]]; then
			$MKDIR "$BKP_DIR"/usr/share/perl
		elif [[ "$DISTRIBUTION" == "Synology" ]]; then
			$MKDIR "$BKP_DIR"/opt/bin
			$MKDIR "$BKP_DIR"/opt/lib
			$MKDIR "$BKP_DIR"/opt/libexec
		else
			$MKDIR "$BKP_DIR"/usr/share/perl5
		fi

		# Apply distro-specific configurations
		if [[ "$DISTRIBUTION" == "Synology" ]]; then
				# Synology DSM restores default /etc/fstab upon reboot,
				# so we better put mount commands in /etc/rc
				if ! grep -q "^# BEGIN: rs-backup-suite" /etc/rc; then
					tmp_name="/tmp/rs-backup_etc-rc.$RANDOM"
					fstab_contents="$(cat ./server/etc/fstab_synology | sed "s#::BACKUP_ROOT::#$BKP_DIR#")"
					tac /etc/rc | sed -e '1!b' -e '/^exit 0$/d' | tac > $tmp_name
					echo "$fstab_contents" >> $tmp_name
					echo "exit 0" >> $tmp_name
					cat $tmp_name > /etc/rc
					rm $tmp_name
				fi

				# Add our own syslog template
				if ! grep -q "^# rs-backup-suite$" /usr/syno/synosdk/texts/enu/events; then
					cat ./server/etc/events_synology >> /usr/syno/synosdk/texts/enu/events
				fi
		else
			if ! grep -q "^# BEGIN: rs-backup-suite" /etc/fstab; then
				if [[ "$DISTRIBUTION" == "Ubuntu" ]]; then
					fstab_local_name="fstab_ubuntu"
				elif [[ "$DISTRIBUTION" == "Synology" ]]; then
					fstab_local_name="fstab_synology"
				else
					fstab_local_name="fstab"
				fi
				fstab_contents="$(cat ./server/etc/$fstab_local_name | sed "s#::BACKUP_ROOT::#$BKP_DIR#")"
				echo "$fstab_contents" >> /etc/fstab
			fi
		fi

		# Do not overwrite existing config
		if [ ! -e "$BKP_DIR"/etc/rsnapshot.global.conf ]; then
			$CP ./server/bkp/etc/* "$BKP_DIR"/etc/
			# Correct command paths in rsnapshot config for Synology DSM
			if [[ "$DISTRIBUTION" == "Synology" ]]; then
				sed -i "s#/usr/bin/\(rsync\|logger\)\$#/opt/bin/\1#" "$BKP_DIR"/etc/rsnapshot.global.conf
			fi
		else
			# Update command paths if upgrading from earlier version
			echo "Updating cp and rm command paths..."
			sed -i "s#/opt/bin/cp\$#/usr/bin/cp#" "$BKP_DIR"/etc/rsnapshot.global.conf
			sed -i "s#/opt/bin/rm\$#/usr/bin/rs-rm#" "$BKP_DIR"/etc/rsnapshot.global.conf
		fi

		# Create symlink for chroot
		dir="$(dirname ${BKP_DIR}${BKP_DIR})"
		if [ ! -d "$dir" ]; then
			$MKDIR "$dir"
		fi
		rel_dir="."
		orig_dir="$(pwd)"
		cd "$dir"
		while [[ "$(realpath .)" != "$(realpath $BKP_DIR)" ]]; do
			if [[ "." == "$rel_dir" ]]; then
				rel_dir=".."
			else
				rel_dir="../$rel_dir"
			fi
			cd ..
		done
		ln -snf "$rel_dir" "${BKP_DIR}${BKP_DIR}"
		cd "$orig_dir"

		echo "Done."
	
	# Client component
	elif [[ $COMPONENT == "all" ]] || [[ $COMPONENT == "client" ]]; then
		echo "Installing client component..."

		$CP ./client/usr/bin/* /usr/bin/
		$CP ./server/usr/bin/rs-version /usr/bin/

		if [ -d /etc/systemd/system ]; then
			echo 'Detected systemd. Run `systemctl enable rs-backup-run.timer` to enable daily backups.'
			$CP ./client/etc/systemd/system/* /etc/systemd/system
		fi

		# Do not overwrite existing config
		if [ ! -e /etc/rs-backup/client-config ]; then
			$CP ./client/etc/rs-backup /etc/
		elif ! $(cmp --silent ./client/etc/rs-backup/client-config /etc/rs-backup/client-config); then
			$CP ./client/etc/rs-backup/client-config /etc/rs-backup/client-config.new
		fi

		echo "Done."
	fi

###############################################################################
# Uninstall mode
###############################################################################
elif [[ "$MODE" == "uninstall" ]]; then
	echo "This will uninstall rs-backup suite from this computer."
	echo "Selected components for removal: $COMPONENT"
	echo "NOTE: This will NOT remove your backup data, just the program!"
	echo
	echo -n "Do you want to continue? [y/N] "
	read answer

	if [[ "$answer" != "Y" ]] && [[ "$answer" != "y" ]]; then
		echo "Okay, no hard feelings. Exiting."
		exit
	fi

	# Server component
	if [[ $COMPONENT == "all" ]] || [[ $COMPONENT == "server" ]]; then
		echo "Uninstalling server component..."

		for i in ./server/usr/bin/*; do
			$RM /usr/bin/"$(basename $i)"
		done

		for i in ./server/usr/sbin/*; do
			$RM /usr/sbin/"$(basename $i)"
		done

		$RM /etc/rs-skel

		[ -e /etc/cron.daily/rs-backup-rotate ]   && $RM /etc/cron.daily/rs-backup-rotate
		[ -e /etc/cron.weekly/rs-backup-rotate ]  && $RM /etc/cron.weekly/rs-backup-rotate
		[ -e /etc/cron.monthly/rs-backup-rotate ] && $RM /etc/cron.monthly/rs-backup-rotate

		if [ -e /etc/crontab ]; then
			echo "Removing crontab entries..."
			sed -i '/^@[a-z]\+ \+\/usr\/sbin\/rs-rotate-cron [a-z]\+$/d' /etc/crontab
		fi

		# Remove fstab entries
		fstab_name="/etc/fstab"
		if [[ "$DISTRIBUTION" == "Synology" ]]; then
			fstab_name="/etc/rc"
		fi
		sed -i '/^# BEGIN: rs-backup-suite$/,/^# END: rs-backup-suite$/d' $fstab_name

		echo "Done."
		
	# Client component
	elif [[ $COMPONENT == "all" ]] || [[ $COMPONENT == "client" ]]; then
		echo "Uninstalling client component..."

		for i in ./client/usr/bin/*; do
			$RM /usr/bin/"$(basename $i)"
		done

		echo "Done."
	fi

	echo -n "Do you want to remove your config files, too? [y/N] "
	read answer
	if [[ "$answer" == "Y" ]] || [[ "$answer" == "y" ]]; then
		echo "Removing config files..."
		$RM /etc/rs-backup
		echo "Done."
	fi

	echo
	echo "INFO: Your backup folder was not removed to preserve your data."
	echo "      If you don't need it anymore, just delete it."
fi
