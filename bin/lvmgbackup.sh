#!/bin/sh
#
# Backup a virtual hard drive that is in use, to a remote server
#
# Originally Written by:	Julian Price, http://www.incharge.co.uk/centos
# Updated by: 			Peter Brooks, http://www.pbrooks.net
# Last Changed:	2009-11-27

source /etc/lvmgbackup/lvmgbackup.conf

################################################################################
# Function definitions

run_hosts(){

	#########################################################################
	# Seek out all configuration hosts and back them up
	local hostdir=$1
	for i in `ls ${1}`
	do
		dbenabled=false
		for j in `cat $1/${i}` 
		#################################################################
		# Get configuration info from file
		do
			key=`echo ${j}|cut -d= -f1`
			value=`echo ${j}|cut -d= -f2`
			case "$key" in
				host)
					vmname=$value
					;;
				enabled)
					enabled=$value
					;;
				vg)
					vg=$value
					;;
				dbenabled)
					dbenabled=$value
					;;
				dbhost)
					dbhost=$value
					;;
				dbuser)
					dbuser=$value
					;;
				dbpassword)
					dbpassword=$value
					;;
				dbport)
					dbport=$value
					;;
				dbtype)
					dbtype=$value
					;;
			esac
		done
		echo "Starting host $i/$vmname" >> $LOGFILE
		if [ -n "${enabled}" -a "${enabled}" = 'true' ]; then
			if [ -n "${vmname}" -a -n "${vg}" ]; then
				# Lock the db if appropriate
				if [ "$dbenabled" = 'true'  ]; then
					dbhandle=$(database_lock $dbtype $dbhost $dbuser $dbpassword $dbport)
				fi				
				
				stop_snapshot $vmname
				start_snapshot $vmname
				if [ "$dbenabled" = 'true'  ]; then
					database_unlock $dbhandle $dbtype
				fi

				synchronise $vmname
				stop_snapshot $vmname
				


			else
				echo "Malformed config for ${i}" >> $ERRFILE
			fi
		fi

	done
	
}

# Connect to the database and lock it
database_lock() {
	echo 'Getting SQL handle' >>$LOGFILE
	case "$1" in
		mysql)
			sqlhandle=`shmysql host=$2 port=$5 user=$3 password=$4`
			shsql $sqlhandle "begin"
			shsql $sqlhandle 'FLUSH TABLES WITH READ LOCK;'
			
			;;
		mssql)
			#sqlhandle=`shfreetds host=$2 port=$5 user=$3 password=$4`
			#shsql $sqlhandle "begin"
			echo "0"
			;;
		esac
	echo $sqlhandle
}

# Unlock the database and close the connection
database_unlock() {
	local sqlhandle=$1
	local sqltype=$2
	echo 'Unlocking database' >>$LOGFILE
	case "$2" in
		mysql)
			echo "Got handle $sqlhandle" >> $LOGFILE
			shsql $sqlhandle 'UNLOCK TABLES;'
			echo 'Ending SQL' >>$LOGFILE
			shsqlend $sqlhandle
			;;
		mssql)
			echo "0" >> $LOGFILE
			;;
	esac
	echo "finished unlocking" >> $LOGFILE
	
}

# Create an LVM snapshot of the VM
start_snapshot() {
	local vmname=$1
	echo 'Creating snapshot' >>$LOGFILE
	SNAPSHOTSIZE=$[`lvdisplay -c /dev/cougar/${vmname} |cut -d: -f7` / 2048/1000]G
	mkdir ${MOUNTPOINT}/${vmname}--snapshot/
	lvcreate --size ${SNAPSHOTSIZE} --snapshot --name ${vmname}-snapshot /dev/${LVMNAME}/${vmname} >>$LOGFILE 2>>$ERRFILE
	kpartx -a /dev/mapper/${LVMNAME}-${vmname}--snapshot
	for i in `ls /dev/mapper/$LVMNAME-${vmname}--snapshot[1-99]` 
	do
		out=`blkid -t TYPE="lvm2pv" $i`
		if [ $? == 0 ];	then #LVM found
			vgscan >> $LOGFILE
			vgname=$(pvdisplay -c ${i}|cut -d: -f2)
			vgchange -ay ${vgname} >> $LOGFILE
			for j in `ls /dev/${vgname}`
			do
				out=`blkid -t TYPE="swap" /dev/${vgname}/$j`
				if [ $? == 2 ]; then
					directory=${MOUNTPOINT}/${vmname}--snapshot/${j}
					mkdir ${directory}
					mount /dev/${vgname}/${j} ${directory}					
				fi
			done
		else #Normal partition
			directory=${MOUNTPOINT}/${vmname}--snapshot/${i#/dev/mapper/${LVMNAME}-${vmname}--snapshot}
			mkdir ${directory}
			mount ${i} ${directory}
		fi
	done
	#Old script#mount ${LVMDEV}/${vmname}-snapshot ${MOUNTPOINT}/${vmname}-snapshot >>$LOGFILE 2>>$ERRFILE
}

#blkid

# Remove the LVM snapshot of the VM
stop_snapshot() {
	local vmname=$1
	if [ -e "${MOUNTPOINT}/${vmname}--snapshot" ]
	then
		echo 'Removing snapshot' >>$LOGFILE
		#Old script#umount ${MOUNTPOINT}/${vmname}-snapshot/
		for i in `ls /dev/mapper/$LVMNAME-${vmname}--snapshot[1-99]` 
		do
			out=`blkid -t TYPE="lvm2pv" $i`
			if [ $? == 0 ]
			then #LVM found
				vgname=$(pvdisplay -c ${i}|cut -d: -f2)
				for j in `ls /dev/${vgname}`
				do
					out=`blkid -t TYPE="swap" /dev/${vgname}/$j`
					if [ $? == 2 ]; then
						directory=${MOUNTPOINT}/${vmname}--snapshot/${j}
						umount ${directory}
						rmdir ${directory}
					fi
				done
				vgchange -an ${vgname} >> $LOGFILE
				
			else #Normal partition
				directory=${MOUNTPOINT}/${vmname}--snapshot/${i#/dev/mapper/${LVMNAME}-${vmname}--snapshot}
				umount ${directory}
				rmdir ${directory}
			fi
		done

		kpartx -d /dev/mapper/${LVMNAME}-${vmname}--snapshot
		lvremove --force /dev/${LVMNAME}/${vmname}-snapshot >>$LOGFILE 2>>$ERRFILE
		rmdir ${MOUNTPOINT}/${vmname}--snapshot/
	fi
}

# Use rsync to synchronise the virtual disk file
synchronise() {
	echo "Starting sync of $1" >> $LOGFILE
	local vmname=$1
	local diskname=$2

	# For testing, put a small test file in ${MOUNTPOINT}/${vmname}
	# and sync this file instead of the virtual disk
	# diskname=test.txt

	echo `date --rfc-2822` ': Synchronizing file'>>$ERRFILE
	#ls ${MOUNTPOINT}/${vmname}-snapshot/ >>$LOGFILE
	for i in `ls ${MOUNTPOINT}/${vmname}--snapshot`
	do
		#rsync -e "ssh -ax -i $REMOTEKEY" -avz ${MOUNTPOINT}/${vmname}--snapshot/${i} ${REMOTEUSERNAME}@${REMOTEIP}:${REMOTEDIR}/${vmname}
		ssh -i ${REMOTEKEY} ${REMOTEUSERNAME}@${REMOTEIP}  "mkdir -p ${REMOTEDIR}/${vmname}/${i}"
		rdiff-backup --force --remote-schema "ssh -ax -i ${REMOTEKEY} %s rdiff-backup --server" ${MOUNTPOINT}/${vmname}--snapshot/${i} ${REMOTEUSERNAME}@${REMOTEIP}::${REMOTEDIR}/${vmname}/${i}
	done
	echo `date --rfc-2822` ': Synchronized file' >>$ERRFILE
}
echo 'Starting backup at' `date --rfc-2822` > $LOGFILE
echo 'Starting backup at' `date --rfc-2822` > $ERRFILE

run_hosts '/etc/lvmgbackup/hosts'

