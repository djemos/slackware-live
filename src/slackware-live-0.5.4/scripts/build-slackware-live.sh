#!/bin/sh

CMDERROR=1
PARTITIONERROR=2
FORMATERROR=3
BOOTERROR=4
INSUFFICIENTSPACE=5

function add_packages() {
	packagesdirectory=$1
	rootdirectory=$2
	packageslistfile=$3
	
	if ! echo $packageslistfile | grep -q "^/"; then
		packageslistfile="`pwd`/$packageslistfile"
	fi
	
	for package in `cat "$packageslistfile" | sed 's/ *#.*//' | sed /=/d`; do
		installpkg -root $rootdirectory $packagesdirectory/$package*.t?z || return $CMDERROR
	done
	
	IFS=$'\n'; 
	pushd $rootdirectory >/dev/null
	for action in `cat "$packageslistfile" | sed 's/^#.*//' | sed -n '/postinstall/p' | cut -f2- -d=`; do
		eval $action
	done
	popd >/dev/null
	
	return 0
}


function init_live() {
	rootdirectory=$1
	livedirectory=$2
	moduleslist=$3
	
	initscriptbasepath=$(dirname $(dirname $0))
	
	mkdir -p $livedirectory/boot
	touch $livedirectory/boot/liveboot
	mkdir -p $livedirectory/boot/modules #don't remove previously created modules
	mkdir -p $livedirectory/boot/optional
	cp -f $rootdirectory/boot/vmlinuz $livedirectory/boot/
	
	#create InitRD
	kv=`ls -l $rootdirectory/boot/vmlinuz | cut -f2 -d'>' | sed s/^[^0-9]*//`
	if [ ! -h $rootdirectory/boot/vmlinuz ] || [ ! -d $rootdirectory/lib/modules/$kv ]; then
		kv=`basename $rootdirectory/lib/modules/*`
	fi

	mount --bind /proc $rootdirectory/proc
	chroot $rootdirectory mkinitrd -c -o /tmp/initrd.gz -s /tmp/initrd-tree -k $kv -m $moduleslist >/dev/null 2>&1
	cd $rootdirectory/tmp/initrd-tree
	find . -name "*.ko"
	cd - >/dev/null
	umount $rootdirectory/proc
	rm -f $rootdirectory/tmp/initrd.gz
	rm -f $rootdirectory/tmp/initrd-tree/{initrd-name,keymap,luksdev,resumedev,rootfs,rootdev,wait-for-root}
	cp $initscriptbasepath/share/slackware-live/init $rootdirectory/tmp/initrd-tree/
	chmod +x $rootdirectory/tmp/initrd-tree/init
	
	cp $initscriptbasepath/sbin/build-slackware-live.sh $rootdirectory/tmp/initrd-tree/
	
	for prg in unionfs mkfs.ext3; do
		cp `which $prg` $rootdirectory/tmp/initrd-tree/bin/ #UnionFS
		ldd `which $prg` | sed 's/[^\/]*\(\/[^ ]*\) .*/\1/' | sed 's/[^\/]*\(\/[^ ]*\) .*/\1/' | sed -n /^\\//p | sort -u | while read lib; do
			if [ -d $rootdirectory/tmp/initrd-tree/lib64 ]
			then cp $lib $rootdirectory/tmp/initrd-tree/lib64/
			else cp $lib $rootdirectory/tmp/initrd-tree/lib/
			fi
		done
	done
	
	find $rootdirectory/tmp/initrd-tree/lib/modules/ -name "*.ko" | xargs strip --strip-unneeded
	cwd=`pwd`
	cd $rootdirectory/tmp/initrd-tree
	rm -f $livedirectory/boot/initrd.gz
	if [ ! -d $livedirectory ]
	then find . | cpio -o -H newc 2>/dev/null | gzip -9c > $cwd/$livedirectory/boot/initrd.gz
	else find . | cpio -o -H newc 2>/dev/null | gzip -9c > $livedirectory/boot/initrd.gz
	fi
	cd - >/dev/null
	rm -rf $rootdirectory/tmp/initrd-tree
	
	#BIOS/syslinux
	mkdir -p $livedirectory/boot/syslinux
	cp /usr/share/syslinux/menu.c32 $livedirectory/boot/syslinux/
	if [ ! -f  $livedirectory/boot/syslinux/syslinux.cfg ]; then
		cat > $livedirectory/boot/syslinux/syslinux.cfg << EOF
prompt 1
timeout 10
default slackware

label slackware
	kernel /boot/vmlinuz
	append max_loop=255 initrd=/boot/initrd.gz runlevel=5
EOF
	fi
	
	#UEFI/elilo
	if [ `uname -m` == "x86_64" ]; then
		mkdir -p $livedirectory/EFI/BOOT
		cp $initscriptbasepath/../boot/elilo-x86_64.efi $livedirectory/EFI/BOOT/bootx64.efi
		cp $livedirectory/boot/initrd.gz $livedirectory/EFI/BOOT/
		cp $livedirectory/boot/vmlinuz $livedirectory/EFI/BOOT/
		if [ ! -f $livedirectory/EFI/BOOT/elilo.conf ]; then
			cat > $livedirectory/EFI/BOOT/elilo.conf << EOF
prompt
timeout=10
default=slackware

image=vmlinuz
	label=slackware
	initrd=initrd.gz
	append="max_loop=255 runlevel=5"
EOF
		fi
		dd if=/dev/zero of=/tmp/efi.img bs=1k count=16384
		mkdosfs -n "EFIBOOT" /tmp/efi.img
		mount -o loop /tmp/efi.img /mnt/floppy
		cp -dpR $livedirectory/EFI /mnt/floppy/
		umount /mnt/floppy
		mv /tmp/efi.img $livedirectory/
	fi
}


function sys_prep() {
	rwdirectory=$1
	shift
	for rodirectory in $*; do rodirectories="$rodirectories:$rodirectory=ro"; done
	
	mkdir /mnt/union
	mount -t aufs -o br=$rwdirectory=rw$rodirectories none /mnt/union 2>/dev/null ||
	unionfs -o allow_other,suid,dev,use_ino,cow,max_files=524288 $rwdirectory=rw$rodirectories /mnt/union
	if [ -x /mnt/union/bin/sh ]; then
		#not done by stock Slackware startup scripts, but by PkgTool during install:
		cat > /mnt/union/sysprep.sh << EOF
#!/bin/sh
if [ -x /usr/bin/update-desktop-database ] && [ -d /usr/share/applications ]; then
	update-desktop-database /usr/share/applications/
fi
if [ -x /usr/bin/mkfontdir ] && [ -d /usr/share/fonts ]; then
	mkfontdir /usr/share/fonts/*
	rm -f /fonts.dir
fi
if [ -x /usr/bin/mkfontscale ] && [ -d /usr/share/fonts ]; then
	mkfontscale /usr/share/fonts/*
	rm -f /fonts.scale
fi
EOF
		#done by stock Slackware startup scripts, but disabled on live startup (for speed improvement)
		cat >> /mnt/union/sysprep.sh << EOF
depmod \`basename /lib/modules/*\`
ldconfig

if [ -x /usr/bin/fc-cache ]; then
	fc-cache -f
fi

if [ -x /usr/bin/gtk-update-icon-cache ] && [ -d /usr/share/icons ]; then
	for theme in /usr/share/icons/*; do gtk-update-icon-cache -t -f \$theme; done
	rm -f /usr/share/icons/icon-theme.cache
fi
if [ -x /usr/bin/update-mime-database ] && [ -d /usr/share/mime ]; then
	update-mime-database /usr/share/mime
fi

if [ -x /usr/bin/update-gtk-immodules ]; then
	update-gtk-immodules #--verbose
fi
if [ -x /usr/bin/update-gdk-pixbuf-loaders ]; then
	update-gdk-pixbuf-loaders #--verbose
fi
if [ -x /usr/bin/update-pango-querymodules ]; then
	update-pango-querymodules #--verbose
fi
EOF
		chmod +x /mnt/union/sysprep.sh
		chroot /mnt/union /sysprep.sh
		rm -f /mnt/union/sysprep.sh
	fi
	umount /mnt/union
	rmdir /mnt/union
	rm -rf $rwdirectory/.wh..wh.* #for AUFS
	
	#merge passwd, group and ld.so.conf
	mkdir -p $rwdirectory/etc
	if (( `find $rwdirectory $* -name passwd | grep etc/passwd | wc -l` > 1 )); then
		find $rwdirectory $* -name passwd | grep etc/passwd | xargs cat | sort -u >> $rwdirectory/etc/passwd.new
		mv -f $rwdirectory/etc/passwd.new $rwdirectory/etc/passwd
		passwdfile="$rwdirectory/etc/passwd"
	else passwdfile=`find $rwdirectory $* -name passwd | grep etc/passwd`
	fi
	if (( `find $rwdirectory $* -name group | grep etc/group | wc -l` > 1 )); then
		find $rwdirectory $* -name group | grep etc/group | xargs cat | sort -u >> $rwdirectory/etc/group.new
		mv -f $rwdirectory/etc/group.new $rwdirectory/etc/group
		groupfile="$rwdirectory/etc/group"
	else groupfile=`find $rwdirectory $* -name group | grep etc/group`
	fi
	if (( `find $rwdirectory $* -name ld.so.conf | wc -l` > 1 )); then
		find $rwdirectory $* -name ld.so.conf | xargs cat | sort -u >> $rwdirectory/etc/ld.so.conf.new
		mv -f $rwdirectory/etc/ld.so.conf.new $rwdirectory/etc/ld.so.conf
	fi
	
	#install profiles
	mkdir -p $rwdirectory/home
	gid=`cat $groupfile | grep "^users:" | cut -f3 -d:`
	find $rwdirectory $* -name skel | grep etc/skel | while read skel; do
		cp -dpR $skel/{*,.??*} $rwdirectory/root 2>/dev/null
		for user in `cat $passwdfile | grep ":$gid:" | cut -f3,6 -d:`; do
			uid=`echo $user | cut -f1 -d:`
			homedir=`echo $user | cut -f2 -d:`
			if echo $homedir | grep -q "/home"; then
				mkdir -p $rwdirectory/$homedir
				cp -dpR $skel/{*,.??*} $rwdirectory/$homedir/ 2>/dev/null
				chown -R $uid:$gid $rwdirectory/$homedir
			fi
		done
	done
}


function add_module() {
	rootdirectory=$1
	livedirectory=$2
	modulename=$3
	if [ "$4" == "-xz" ] || [ "$4" == "-gzip" ]; then
		if [ "$4" == "-gzip" ]
		then compoption="-comp gzip"
		else compoption="-comp xz -b 1M"
		fi
	else compoption=""
		option=$4
	fi
	
	if [ "$option" == "-optional" ]
	then modulepath=$livedirectory/boot/optional/$modulename
	else modulepath=$livedirectory/boot/modules/$modulename
	fi
	mkdir -p `dirname $modulepath`
	rm -f $modulepath
	mksquashfs $rootdirectory $modulepath $compoption -e tmp dev proc sys $livedirectory
}


function create_iso() {
	livedirectory=$1
	imagefilename=$2
	
	cp /usr/share/syslinux/isolinux.bin $livedirectory/boot/syslinux/
	if [ `uname -m` == "x86_64" ]; then
		altboot="-eltorito-alt-boot -no-emul-boot -eltorito-platform efi -eltorito-boot efi.img"
	fi
	mkisofs -J -d -N -l -r -V "Slackware-Live" -hide-rr-moved -o $imagefilename \
		-b boot/syslinux/isolinux.bin -boot-load-size 4 -boot-info-table -no-emul-boot \
		-c boot/syslinux/boot.catalog -hide boot.catalog -hide-joliet boot.catalog $altboot \
	   $livedirectory
}


function install_usb() {
	livedirectory=$1
	installmedia=$2
	
	device=`echo $installmedia | cut -c6-8`
	sectorscount=`cat /sys/block/$device/size`
	sectorsize=`cat /sys/block/$device/queue/hw_sector_size`
	let mediasize=$sectorscount*$sectorsize/1048576 #in MB
	installdevice="/dev/$device"
	livesystemsize=`du -s -m $livedirectory | sed 's/\t.*//'`

	if [ "$installdevice" == "$installmedia" ]; then #install on whole disk: partition and format media
		if [ `uname -m` == "x86_64" ]; then #EFI/GPT
			partitionnumber=2
			installmedia="$installdevice$partitionnumber"
			dd if=/dev/zero of=$installdevice bs=512 count=34 >/dev/null 2>&1
			echo -e "2\nn\n\n\n+32M\nef00\nn\n\n\n\n\nr\nh\n1 2\nn\n\ny\n\nn\n\nn\nwq\ny\n" | gdisk $installdevice || return $PARTITIONERROR
			partprobe $installdevice >/dev/null 2>&1; sleep 3
			mkfs.fat -n "efi"  $installdevice"1" || return $FORMATERROR
			mkfs.ext3 -L "Slackware-Live" $installmedia || return $FORMATERROR
		else #BIOS/MBR
			partitionnumber=4
			installmedia="$installdevice$partitionnumber"
			if (( $mediasize < 2048 ))
			then heads=128; sectors=32
			else heads=255; sectors=63
			fi
			mkdiskimage $installdevice 1 $heads $sectors || return $PARTITIONERROR
			dd if=/dev/zero of=$installdevice bs=1 seek=446 count=64 >/dev/null 2>&1
			echo -e ',0\n,0\n,0\n,,83,*' | sfdisk $installdevice || return $PARTITIONERROR
			partprobe $installdevice; sleep 3
			mkfs.ext3 -L "Slackware-Live" $installmedia || return $FORMATERROR
		fi
		sleep 3
	
	else #install on partition: filesystem check and format if needed
		partitionnumber=`echo $installmedia | cut -c9-`
		mkdir -p /mnt/tmp
		if mount $installmedia /mnt/tmp >/dev/null 2>&1; then
			sleep 1
			umount /mnt/tmp
			fsck -fy $installmedia >/dev/null 2>&1
		else #format partition
			if fdisk -l $installdevice 2>/dev/null | grep -q GPT; then
				partitiontype=`gdisk -l $installdevice | grep "^  *$partitionnumber " | sed 's/  */:/g' | cut -f7 -d:`
			else
				partitiontype=`fdisk -l $installdevice 2>/dev/null | grep "^$installmedia " | sed -e 's/\*//' -e 's/  */:/g' | cut -f5 -d:`
			fi
			case $partitiontype in
			83|8300) 
				mkfs.ext3 -L "Slackware-Live" $installmedia || return $FORMATERROR
				;;
			*)
				partition=`echo $installmedia | cut -c6-`
				size=`cat /proc/partitions | grep " $partition$" | sed 's/  */:/g' | cut -f4 -d:`
				let size=$size/1024
				if (( $size > 1024 )); then
					fat32option="-F 32"
				fi
				mkfs.fat $fat32option -n "Slackware-Live" $installmedia || return $FORMATERROR
			esac
			sleep 3
		fi
	fi
	
	#live system files copy
	if [ `uname -m` == "x86_64" ]; then #EFI/GPT
		efipartition="$installdevice"`gdisk -l $installdevice 2>/dev/null | grep " EF00 " | sed 's/  */:/g' | cut -f2 -d:`
		if [ ! -z "$efipartition" ] && [ "$efipartition" != "$installmedia" ]; then
			mkdir -p /mnt/tmp
			if mount $efipartition /mnt/tmp >/dev/null 2>&1; then
				sleep 1
				umount /mnt/tmp
			else
				mkfs.fat -n  "efi" $efipartition || return $FORMATERROR
			fi
			mkdir -p /mnt/efi
			mount $efipartition /mnt/efi
			cp -r $livedirectory/EFI /mnt/efi/
			umount /mnt/efi
			rmdir /mnt/efi
		fi
	fi
	
	mkdir -p /mnt/install
	mount $installmedia /mnt/install
	cp -r $livedirectory/boot /mnt/install/
	if [ `uname -m` == "x86_64" ]; then #EFI/GPT
		cp -r $livedirectory/EFI /mnt/install/
		cp $livedirectory/efi.img /mnt/install/
	fi
	if fdisk -l $installdevice 2>/dev/null | grep -q "^$installmedia "; then #legacy / CSM (Compatibility Support Module) boot, if $installmedia present in MBR (or hybrid MBR)
		sfdisk --force $installdevice -A $partitionnumber 2>/dev/null
		if mount | grep -q "^$installmedia .* vfat "; then #FAT32
			umount /mnt/install
			syslinux -d /boot/syslinux $installmedia || return $BOOTERROR
		else #Ext3 
			extlinux -i /mnt/install/boot/syslinux || return $BOOTERROR
			umount /mnt/install
		fi
		cat /usr/share/syslinux/mbr.bin > $installdevice
	else
		umount /mnt/install
	fi
	rmdir /mnt/install
	
	return 0
}


function install_system() {
	rootdirectory=$1
	systempart=$2
	loadersetup=$3
	SYSINSTALLFS="ext4"
	
	mkfs.$SYSINSTALLFS $systempart || return $FORMATERROR

	mkdir -p /mnt/install
	mount $systempart /mnt/install

	#Copy begin
	for directory in $rootdirectory/*; do
		cp -dpr $directory /mnt/install/
	done
	
	mkdir -p /mnt/install/{dev,proc,sys,tmp}
	cp -dpr /dev/sd* /mnt/install/dev/ #create disk nodes needed for LiLo
	cp -dpr $rootdirectory/lib/udev/devices/* /mnt/install/dev/

	sed -i /^root:/d /mnt/install/etc/shadow #setup root password
	cat /etc/shadow | sed -n /^root:/p >> /mnt/install/etc/shadow
	
	if [ -f /etc/rc.d/rc.keymap ]; then
		cp -f /etc/rc.d/rc.keymap /mnt/install/etc/rc.d/
	fi
	cp -f /etc/profile.d/lang.sh /mnt/install/etc/profile.d/
	if [ -f /etc/X11/xorg.conf.d/20-keyboard.conf ]; then
		cp -f /etc/X11/xorg.conf.d/20-keyboard.conf /mnt/install/etc/X11/xorg.conf.d/
	fi
	if [ -f /etc/X11/xorg.conf ]; then
		cp -f /etc/X11/xorg.conf /mnt/install/etc/X11/
	fi
	if [ -f /etc/localtime ] &&  [ -h /etc/localtime-copied-from  ]; then
		cp -f /etc/localtime /mnt/install/etc/
		cp -df /etc/localtime-copied-from /mnt/install/etc/
	fi
	if [ -f /etc/hardwareclock ]; then
		cp -f /etc/hardwareclock /mnt/install/etc/
	fi
	#Copy end

	#FSTab begin
	cat > /mnt/install/etc/fstab << EOF
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
$systempart / $SYSINSTALLFS defaults 1 1
EOF
	cat /etc/fstab | grep " swap " >> /mnt/install/etc/fstab
	cat /etc/fstab | grep "/mnt" |  grep -v "$systempart" >> /mnt/install/etc/fstab
	cat /etc/fstab | grep "/mnt" |  grep -v "$systempart" | cut -f2 -d' ' | while read mountpoint; do
		mkdir /mnt/install$mountpoint
	done
	echo "$systempart / $SYSINSTALLFS defaults 1 1" > /mnt/install/etc/mtab
	#FSTab end
	
	#InitRD begin
	if [ ! -f /mnt/install/boot/initrd.gz ]; then
		kv=`basename /mnt/install/lib/modules/*`
		if lsmod | grep -q $SYSINSTALLFS; then
			moduleslist="$SYSINSTALLFS"
		fi
		for module in `lsmod | sed 1d | cut -f1 -d' '`; do 
			modulebis=`echo $module | sed 's/_/-/g'` #'_' -> '-'
			if [ -f /lib/modules/$kv/kernel/drivers/ata/$module.ko ] || [ -f /lib/modules/$kv/kernel/drivers/scsi/$module.ko ]; then
				moduleslist="$module:$moduleslist"
			fi
			if [ "$module" != "$modulebis" ]; then
				if [ -f /lib/modules/$kv/kernel/drivers/ata/$modulebis.ko ] || [ -f /lib/modules/$kv/kernel/drivers/scsi/$modulebis.ko ]; then
					moduleslist="$modulebis:$moduleslist"
				fi
			fi
		done
		moduleslist=`echo $moduleslist | sed 's/:$//'`
		if [ ! -z "$moduleslist" ] && [ "$moduleslist" != "sg" ]; then
			chroot /mnt/install mount /proc
			chroot /mnt/install mkinitrd -c -f $SYSINSTALLFS -r $systempart -k $kv -m $moduleslist
			chroot /mnt/install umount /proc
		fi
	fi
	#InitRD end
	
	#LiLo begin
	if [ "$loadersetup" == "-auto" ]; then
		installdevice=`echo $systempart | cut -c1-8`
		if [ -d /sys/firmware/efi ]; then #UEFI
			modprobe efivars
			efipartnum=`gdisk -l $installdevice | grep "EF00" | sed 's/  \+/ /g' | cut -f2 -d' '`
			efipartition="$installdevice$efipartnum"
			if [ ! -z "$efipartition" ]; then
				mkdir -p /mnt/efi
				mount $efipartition /mnt/efi
				efilabel="Slackware"
				if [ -d /mnt/efi/EFI/$efilabel ]; then
					conflictpart=`cat /mnt/efi/EFI/$efilabel/elilo.conf | grep "append" | sed 's/.*root=\([^ ]*\).*/\1/'`
					if [ "$conflictpart" == "$systempart" ]
					then efibootid=`efibootmgr | grep $efilabel | cut -b5-8`
						efibootmgr -q -B -b $efibootid
					else efilabel="$efilabel`ls /mnt/efi/EFI/ | grep "$efilabel" | wc -l`"
					fi
				fi
				mkdir -p /mnt/efi/EFI/$efilabel
				cp /mnt/install/boot/elilo-x86_64.efi /mnt/efi/EFI/$efilabel/elilo.efi
				cp /mnt/install/boot/vmlinuz /mnt/efi/EFI/$efilabel/
				cat > /mnt/efi/EFI/$efilabel/elilo.conf << EOF
timeout=1
default=slackware

image=vmlinuz
    label=slackware
    append="root=$systempart ro"
	read-only
EOF
				if [ -f /mnt/install/boot/initrd.gz ]; then
					echo "  initrd=initrd.gz" >> /mnt/efi/EFI/$efilabel/elilo.conf
					cp /mnt/install/boot/initrd.gz /mnt/efi/EFI/$efilabel/
				fi
				umount /mnt/efi
				rmdir /mnt/efi
				efibootmgr -q -c -d $installdevice -p $efipartnum -l "\\EFI\\$efilabel\\elilo.efi" -L "Slackware ($systempart)"
			fi
		else #BIOS
			echo "boot = $installdevice" > /mnt/install/etc/lilo.conf
			if [ -f /mnt/install/boot/slack.bmp ]; then
				cat >> /mnt/install/etc/lilo.conf << EOF

bitmap = /boot/slack.bmp
bmp-colors = 255,0,255,0,255,0
bmp-table = 60,6,1,16
bmp-timer = 65,27,0,255

vga = 791

EOF
			fi
			cat >> /mnt/install/etc/lilo.conf << EOF
lba32

prompt
timeout = 50
compact

image = /boot/vmlinuz
root = $systempart
label = Linux
read-only
EOF
			if [ -f /mnt/install/boot/initrd.gz ]; then
				echo "initrd = /boot/initrd.gz" >> /mnt/install/etc/lilo.conf
			fi
			windowspartition=`fdisk -l $installdevice 2>/dev/null | grep "^$installdevice.*\*.*\(NTFS\|FAT32\)" | cut -f1 -d' '`
			if [ ! -z "$windowspartition" ]; then
				cat >> /mnt/install/etc/lilo.conf << EOF

other = $windowspartition
label = Windows
table = $installdevice
EOF
			fi
			chroot /mnt/install mount /proc
			chroot /mnt/install lilo || return $BOOTERROR
			chroot /mnt/install umount /proc
		fi
	fi
	#LiLo end
	
	umount /mnt/install
	rmdir /mnt/install
	
	return 0
}


function share_live() {
	livedirectory=$1
	listeniface=$2
	iprange=$3
	moduleslist=$4
	
	#backups
	if [ ! -f /etc/export.sl ]; then mv /etc/exports{,.sl}; fi
	if [ ! -f /etc/dhcpd.conf.sl ]; then mv /etc/dhcpd.conf{,.sl}; fi
	
	#retrieve network parameters
	serverip=`ifconfig $listeniface | sed -n 2p | sed 's/  */:/g' | cut -f3 -d:`
	netmask=`ifconfig $listeniface | sed -n 2p | sed 's/  */:/g' | cut -f5 -d:`
	gateway=`route -n | sed  -n /^0.0.0.0/p | sed s/\ \ */:/g | cut -f2 -d:`
	nameserver=`cat /etc/resolv.conf | grep nameserver | sed -n 1p | cut -f2 -d' '`
	if [ "$gateway" == "0.0.0.0" ]; then
		gateway=$serverip
		nameserver=$serverip
	fi
	network=`ifconfig $listeniface | sed -n 2p | sed 's/  */:/g' | cut -f7 -d: | sed 's/255/0/g'`
	
	#setup NFS server
	echo "$livedirectory $network/$netmask(ro,no_root_squash,no_all_squash,async,no_subtree_check)" > /etc/exports
	. /etc/rc.d/rc.nfsd start
	
	#setup TFTP booting
	mkdir -p /tftpboot/boot
	cp $livedirectory/boot/* /tftpboot/boot/ 2>/dev/null #copy only files
	cp /usr/share/syslinux/pxelinux.0 /tftpboot/
	cp -r $livedirectory/boot/syslinux /tftpboot/pxelinux.cfg
	rm -f /tftpboot/pxelinux.cfg/{ldlinux.sys,isolinux.bin}
	mv /tftpboot/pxelinux.cfg/{syslinux.cfg,default}
	for configfile in `find /tftpboot/pxelinux.cfg/* ! -name "*.png" ! -name "*.jpg" ! -name "*.c32"`; do
		sed -i "s@append @append nfsroot=$serverip:$livedirectory @" $configfile
		sed -i 's/\(timeout.*\)/\1\nipappend 1/' $configfile
	done
	mv /tftpboot/pxelinux.cfg/* /tftpboot/
	mv /tftpboot/default /tftpboot/pxelinux.cfg/
	
	sed -i s/^\#\ tftp/tftp/ /etc/inetd.conf
	. /etc/rc.d/rc.inetd start
	
	#append net drivers to InitRD
	if [ ! -z "$moduleslist" ]; then
		for initrd in /tftpboot/boot/*.gz; do #for each suspected initrd file
			mkdir /tmp/initrd-tree
			cd /tmp/initrd-tree
			if gunzip -c $initrd | cpio -i 2>/dev/null && [ -d lib/modules ]; then #if it is really an initrd
				kv=`basename lib/modules/*`
				mkinitrd -c -o /tmp/initrd.gz -s /tmp/initrd-tree-bis -k $kv -m $moduleslist
				rm -f /tmp/initrd.gz
				cp -r /tmp/initrd-tree-bis/lib/modules/* lib/modules/
				cat /tmp/initrd-tree-bis/load_kernel_modules >> load_kernel_modules
				rm -rf /tmp/initrd-tree-bis
				find lib/modules/ -name "*.ko" | xargs strip --strip-unneeded
				chroot . depmod $kv
				find . | cpio -o -H newc | gzip -9c > $initrd
			fi
			cd - >/dev/null
			rm -rf /tmp/initrd-tree
		done
	fi
	
	#setup DHCP server
	if ! dhcpcd -T -t 1 $listeniface 2>&1 | grep -q IPv4LL
	then rangeprefix=`echo $serverip | cut -f1-3 -d .` #only the last byte is used for network machine number
		rangebegin=`echo $iprange | cut -f1 -d-`
		rangeend=`echo $iprange | cut -f2 -d-`
		cat > /etc/dhcpd.conf << EOF
ddns-update-style none;
option routers $gateway;
option domain-name-servers $nameserver;

subnet $network netmask $netmask {
	range $rangeprefix.$rangebegin $rangeprefix.$rangeend;
	filename "pxelinux.0";
	next-server $serverip; #TFTP server
}
EOF
		rm -f /var/state/dhcp/dhcpd.leases; touch /var/state/dhcp/dhcpd.leases #needed on live system
		dhcpd $listeniface
	else echo "a DHCP server is already running - PXE parameters are:"
		echo -e "\tfilename \"pxelinux.0\"; #(option 67 on Windows)\n\tnext-server $serverip; #(option 66 on Windows)"
	fi
}


function unshare_live() {
	. /etc/rc.d/rc.nfsd stop
	. /etc/rc.d/rc.inetd stop
	killall dhcpd
	sed -i s/^tftp/\#\ tftp/ /etc/inetd.conf
	if [ -f /etc/export.sl ]; then mv /etc/exports{.sl,}; fi
	if [ -f /etc/dhcpd.conf.sl ]; then mv /etc/dhcpd.conf{.sl,}; fi
}


action=$1
case $action in
"--add")
	packagesdirectory=$2
	rootdirectory=$3
	packageslistfile=$4
	if [ -d "$packagesdirectory" ] && [ ! -z "$rootdirectory" ] && [ -f "$packageslistfile" ]; then
		add_packages $packagesdirectory $rootdirectory $packageslistfile
	else
		echo -e "`basename $0` --add packages_dir root_dir pkg_list_file"
		exit $CMDERROR
	fi
	;;
"--init")
	rootdirectory=$2
	livedirectory=$3
	moduleslist=$4
	if [ -d "$rootdirectory" ] && [ ! -z "$livedirectory" ]; then
		if [ -z "$moduleslist" ]; then
			moduleslist="squashfs:fuse:loop:ehci-pci:xhci-hcd:usb-storage"
		fi
		init_live $rootdirectory $livedirectory $moduleslist
	else
		echo "`basename $0` --init root_dir live_dir [modules_list]"
		exit $CMDERROR
	fi
	;;
"--sysprep")
	rwdirectory=$2
	if [ -d "$rwdirectory" ]; then
		shift; shift 
		sys_prep "$rwdirectory" $*
	else
		echo "`basename $0` --sysprep root_dir_1(rw) root_dir_2(ro) ..."
		exit $CMDERROR
	fi
	;;
"--module")
	rootdirectory=$2
	livedirectory=$3
	modulename=$4
	if [ "$5" == "-xz" ] || [ "$5" == "-gzip" ]; then
		compression=$5
		option=$6
	else
		option=$5
	fi
	if [ -d "$rootdirectory" ] && [ -d "$livedirectory" ] && [ ! -z "$modulename" ]; then
		add_module $rootdirectory $livedirectory $modulename $compression $option
	else
		echo "`basename $0` --module root_dir live_dir module_file_name [-xz|-gzip] [-optional]"
		exit $CMDERROR
	fi
	;;
"--iso")
	livedirectory=$2
	imagefilename=$3
	if [ -d "$livedirectory" ] && [ -d "`dirname $imagefilename`" ] && [ ! -d "$imagefilename" ]; then
		create_iso $livedirectory $imagefilename
	else
		echo "`basename $0` --iso live_dir iso_file"
		exit $CMDERROR
	fi
	;;
"--usb")
	livedirectory=$2
	installmedia=$3
	if [ -d "$livedirectory" ] && [ -b "$installmedia" ]; then
		livesystemsize=`du -s -m $livedirectory | sed 's/\t.*//'`
		device=`echo $installmedia | cut -c6-8`
		partition=`echo $installmedia | cut -c6-`
		sectorscount=`cat /sys/block/$device/subsystem/$partition/size`
		sectorsize=`cat /sys/block/$device/queue/hw_sector_size`
		let destinationsize=$sectorscount*$sectorsize/1048576
		if (( $livesystemsize > $destinationsize)); then 
			echo "error: insufficant space on device '$installmedia'"
			exit $INSUFFICIENTSPACE
		else
			install_usb $livedirectory $installmedia
			exit $!
		fi
	else
		echo "`basename $0` --usb live_dir device"
		exit $CMDERROR
	fi
	;;
"--install")
	rootdirectory=$2
	systempart=$3
	loadersetup=$4
	if [ -d "$rootdirectory" ] && [ -b "$systempart" ]; then
		systemsize=`du -s -m $rootdirectory | sed 's/\t.*//'`
		device=`echo $systempart | cut -c6-8`
		partition=`echo $systempart | cut -c6-`
		sectorscount=`cat /sys/block/$device/subsystem/$partition/size`
		sectorsize=`cat /sys/block/$device/queue/hw_sector_size`
		let destinationsize=$sectorscount*$sectorsize/1048576
		if (( $systemsize > $destinationsize)); then 
			echo "error: insufficant space on device '$systempart'"
			exit $INSUFFICIENTSPACE
		else
			install_system $rootdirectory $systempart $loadersetup
			exit $!
		fi
	else
		echo "`basename $0` --install root_dir device [-auto|-expert]"
		exit $CMDERROR
	fi
	;;
"--share")
	livedirectory=$2
	listeniface=$3
	iprange=$4
	moduleslist=$5
	if [ -d "$livedirectory" ] && ifconfig | grep -q "$listeniface:" && [ ! -z "$iprange" ]; then
		if [ "$moduleslist" == "auto" ]; then
			moduleslist=""
			for module in `lsmod | cut -f1 -d' '`; do 
				if [ ! -z `find /lib/modules/*/kernel/drivers/net -name "$module.ko"` ]; then
					moduleslist+=":$module"
				fi
			done
			moduleslist=`echo $moduleslist | cut -c2-`
		fi
		unshare_live
		share_live $livedirectory $listeniface $iprange $moduleslist
	else
		echo "`basename $0` --share live_system_dir listen_interface ip_range [modules_list|auto]"
		exit $CMDERROR
	fi
	;;
"--unshare")
	unshare_live
	;;
*)	echo "`basename $0` --add packages_dir root_dir pkg_list_file"
	echo "`basename $0` --sysprep root_dir_1(rw) root_dir_2(ro) ..."
	echo "`basename $0` --init root_dir live_dir [modules_list]"
	echo "`basename $0` --module root_dir live_dir module_file [-xz|-gzip] [-optional]"
	echo "`basename $0` --iso live_dir iso_file"
	echo "`basename $0` --usb live_dir device"
	echo "`basename $0` --install root_dir device [-auto|-expert]"
	echo "`basename $0` --share live_dir listen_interface ip_range [modules_list|auto]"
	echo "`basename $0` --unshare"
	exit $CMDERROR
	;;
esac
