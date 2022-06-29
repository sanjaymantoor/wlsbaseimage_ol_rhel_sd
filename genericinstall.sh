#!/bin/bash

#Function to output message to StdErr
function echo_stderr ()
{
    echo "$@" >&2
}

#Function to display usage message
function usage()
{
  echo_stderr "./genericinstall.sh <acceptOTNLicenseAgreement> <otnusername> <otnpassword> <shiphomeurl> <jdkurl> <wlsversion> <jdkversion> <linux version> <opatch URL> <wlspatch URL>"
  echo_stderr " Supply none in case opatch/wlspatch update is not required"
}

#Check the execution success
function checkSuccess()
{
	retValue=$1
	message=$2
	if [[ $retValue != 0 ]]; then
		echo_stderr "${message}"
		exit $retValue
	fi
}

#Function to cleanup all temporary files
function cleanup()
{
    echo "Cleaning up temporary files..."

    rm -f $BASE_DIR/*.tar.gz
    rm -f $BASE_DIR/*.zip

    rm -rf $JDK_PATH/*.tar.gz
    rm -rf $WLS_PATH/*.zip

    rm -rf $WLS_PATH/silent-template

    rm -rf $WLS_JAR
    
    sudo rm -rf ${opatchWork}
    sudo rm -rf ${wlsPatchWork}
    
    echo "Cleanup completed."
    
}

# RedHat root file system has of size 2GB which is less for WLS setup
# This function increases the disk size around 30 GB
function resizeDisk()
{
   if [ "$linuxversion" == "7.3" ]
   then
      partition=`df -hP / | awk '{print $1}' | tail -1`
      volume=${partition}
   else
      partition=`pvscan | head -1 | awk '{print $2}'`
      volume=`df -hP / | awk '{print $1}' | tail -1`
   fi   
   fileSystemNumber=${partition: -1}
   fileSystemName=${partition::-1}
   echo "File system name : $fileSystemName"
   echo "File system number : $fileSystemNumber"
   sudo df -h ${volume}
   sudo growpart $fileSystemName $fileSystemNumber --fudge 2048 | true
   sudo lsblk ${partition}
   sudo lvextend -An -L+28G --resizefs $volume
   sudo pvresize ${partition}
   echo "After resizing $volume size"
   sudo df -Th ${volume}
}

#function to mount data disk
function mountDataDisk()
{
   echo "Attempting to mount data disk"
   # Assuming data disk will have disk with /dev/sdc
   sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%
   sudo mkfs.xfs /dev/sdc1
   sudo partprobe /dev/sdc1
   sudo mkdir /u01
   mountString=`sudo blkid | grep sdc1 | cut -f2 -d":" | cut -f2 -d" "`
   sudo echo "$mountString /u01   xfs   defaults,nofail   1   2" >> /etc/fstab
   if [[ $? != 0 ]];
   then
      echo "data disk mount entry for /etc/fstab failed"
      exit 1
   fi
   sudo mount /u01
   sudo df -h /u01
   if [[ $? != 0 ]];
   then
      echo "data disk /u01 mount failed"
      exit 1
   fi      
}

#This function is to create swapfile required for WebLogic installation
# This is temporary swap to be created for WLS but for permanent it needs to be created using createSwapWithWALinux
function createSwap()
{

   #Check if already swap is present
   swapfile=`swapon -s | tail -1 | awk '{print $1}'`
   if [ -z $swapfile ]
   then
  	echo "Creating swapfile $SWAP_FILE for WLS installation"
   	sudo mkdir -p $SWAP_FILE_DIR
   	sudo fallocate --length 2GiB $SWAP_FILE
   	sudo chmod 600 $SWAP_FILE
   	sudo mkswap $SWAP_FILE
   	sudo swapon $SWAP_FILE
   	sudo swapon -a
   	sudo swapon -s
   	sleep 2s
   	echo "Verifying swapfile is created"
   	if [ -f $SWAP_FILE ]; then
      		echo "Swap partition created at $SWAP_FILE"
   	else
      		echo "Swap partition creation failed"
      		exit 1
   	fi
	createSwapWithWALinux
   else
   	echo "Swap already exists $swapfile"
	sudo swapon -s
   fi
}


#This function to enable swap partiftion using WALinux Agent
#createSwap function will enable temporarily partition for WLS installation, but that causes Azure certification to fail
# saying swap partition is not allowed. Hence before creating base image it needs to be swapoff and then use WALinux agent
# configuration. 
# WALinux agent requires manual restart. Restart can't be done as part of deployment , as it causes deployment to run forever
function createSwapWithWALinux()
{
   echo "Creating swapfile using waagent service"
   sudo cp /etc/waagent.conf /etc/waagent.conf.backup
   sudo sed -i 's,ResourceDisk.MountPoint=\/mnt\/resource,ResourceDisk.MountPoint='"$SWAP_FILE_DIR"',' /etc/waagent.conf
   sudo sed -i 's/ResourceDisk.Format=n/ResourceDisk.Format=y/g' /etc/waagent.conf
   sudo sed -i 's/ResourceDisk.EnableSwap=n/ResourceDisk.EnableSwap=y/g' /etc/waagent.conf
}


#download 3rd Party JDBC Drivers
function downloadJDBCDrivers()
{
   echo "Downloading JDBC Drivers..."

   echo "Downloading postgresql Driver..."
   downloadUsingWget ${POSTGRESQL_JDBC_DRIVER_URL}

   echo "Downloading mssql Driver"
   downloadUsingWget ${MSSQL_JDBC_DRIVER_URL}

   echo "JDBC Drivers Downloaded Completed Successfully."
}


#Download and install weblogic-deploy-tool as per URL WEBLOGIC_DEPLOY_TOOL
function setupWDT()
{
    DIR_PWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    echo "Creating domain path /u01/domains"
    echo "Downloading weblogic-deploy-tool"
    DOMAIN_PATH="/u01/domains" 
    sudo mkdir -p $DOMAIN_PATH 
    sudo rm -rf $DOMAIN_PATH/*

    cd $DOMAIN_PATH
    wget -q $WEBLOGIC_DEPLOY_TOOL
    if [[ $? != 0 ]]; then
       echo "Error : Downloading weblogic-deploy-tool failed"
       exit 1
    fi
    sudo unzip -o weblogic-deploy.zip -d $DOMAIN_PATH
    sudo chown -R $username:$groupname $DOMAIN_PATH
    rm $DOMAIN_PATH/weblogic-deploy.zip
    cd $DIR_PWD
}

# Download files supplied as part of downloadURL
function downloadUsingWget()
{
   downloadURL=$1
   filename=${downloadURL##*/}
   for in in {1..5}
   do
     echo wget --no-check-certificate $downloadURL
     wget --no-check-certificate $downloadURL
     if [ $? != 0 ];
     then
        echo "$filename Driver Download failed on $downloadURL. Trying again..."
	rm -f $filename
     else 
        echo "$filename Driver Downloaded successfully"
        break
     fi
   done
}

#Copy the JDBC drivers POSTGRESQL and MYSQL then set in WEBLOGIC_CLASSPATH
function copyJDBCDriversToWeblogicClassPath()
{
     echo "Copying JDBC Drivers to Weblogic CLASSPATH ..."
     sudo cp $BASE_DIR/${POSTGRESQL_JDBC_DRIVER} ${WL_HOME}/server/lib/
     sudo cp $BASE_DIR/${MSSQL_JDBC_DRIVER} ${WL_HOME}/server/lib/

     chown $username:$groupname ${WL_HOME}/server/lib/${POSTGRESQL_JDBC_DRIVER}
     chown $username:$groupname ${WL_HOME}/server/lib/${MSSQL_JDBC_DRIVER}

     echo "Copied JDBC Drivers to Weblogic CLASSPATH"
}

# Verify whether JDBC drivers jars are in location 
function testJDBCDrivers()
{

	# Temporarily added for test
	ls /u01/app/wls/install/oracle/middleware/oracle_home/wlserver/server/lib/postgresql-42.3.6.jar
	if [[ $? != 0 ]]; then
   		echo Downloading postgresql-42.3.6.jar failed
   		exit 1
	fi
	
	ls /u01/app/wls/install/oracle/middleware/oracle_home/wlserver/server/lib/mssql-jdbc-10.2.1.jre8.jar
	if [[ $? != 0 ]]; then
   		echo Downloading mssql-jdbc-10.2.1.jre8.jar failed
   		exit 1
	fi
}

# Update the WEBLOGIC_CLASSPATH
function modifyWLSClasspath()
{
  echo "Modify WLS CLASSPATH ...."
  sed -i 's;^WEBLOGIC_CLASSPATH=\"${JAVA_HOME}.*;&\nWEBLOGIC_CLASSPATH="${WL_HOME}/server/lib/postgresql-42.3.6.jar:${WL_HOME}/server/lib/mssql-jdbc-10.2.1.jre8.jar:${WEBLOGIC_CLASSPATH}";' ${WL_HOME}/../oracle_common/common/bin/commExtEnv.sh
  sed -i 's;^WEBLOGIC_CLASSPATH=\"${JAVA_HOME}.*;&\n\n#**WLSAZURECUSTOMSCRIPTEXTENSION** Including Postgresql and MSSSQL JDBC Drivers in Weblogic Classpath;' ${WL_HOME}/../oracle_common/common/bin/commExtEnv.sh
  echo "Modified WLS CLASSPATH."
}


#Function to create Weblogic Installation Location Template File for Silent Installation
function create_oraInstlocTemplate()
{
    echo "creating Install Location Template..."

    cat <<EOF >$WLS_PATH/silent-template/oraInst.loc.template
inventory_loc=[INSTALL_PATH]
inst_group=[GROUP]
EOF
}

#Function to create Weblogic Installation Response Template File for Silent Installation
function create_oraResponseTemplate()
{

    echo "creating Response Template..."

    cat <<EOF >$WLS_PATH/silent-template/response.template
[ENGINE]

#DO NOT CHANGE THIS.
Response File Version=1.0.0.0.0

[GENERIC]

#Set this to true if you wish to skip software updates
DECLINE_AUTO_UPDATES=false

#My Oracle Support User Name
MOS_USERNAME=

#My Oracle Support Password
MOS_PASSWORD=<SECURE VALUE>

#If the Software updates are already downloaded and available on your local system, then specify the path to the directory where these patches are available and set SPECIFY_DOWNLOAD_LOCATION to true
AUTO_UPDATES_LOCATION=

#Proxy Server Name to connect to My Oracle Support
SOFTWARE_UPDATES_PROXY_SERVER=

#Proxy Server Port
SOFTWARE_UPDATES_PROXY_PORT=

#Proxy Server Username
SOFTWARE_UPDATES_PROXY_USER=

#Proxy Server Password
SOFTWARE_UPDATES_PROXY_PASSWORD=<SECURE VALUE>

#The oracle home location. This can be an existing Oracle Home or a new Oracle Home
ORACLE_HOME=[INSTALL_PATH]/oracle/middleware/oracle_home

#Set this variable value to the Installation Type selected. e.g. WebLogic Server, Coherence, Complete with Examples.
INSTALL_TYPE=WebLogic Server

#Provide the My Oracle Support Username. If you wish to ignore Oracle Configuration Manager configuration provide empty string for user name.
MYORACLESUPPORT_USERNAME=

#Provide the My Oracle Support Password
MYORACLESUPPORT_PASSWORD=<SECURE VALUE>

#Set this to true if you wish to decline the security updates. Setting this to true and providing empty string for My Oracle Support username will ignore the Oracle Configuration Manager configuration
DECLINE_SECURITY_UPDATES=true

#Set this to true if My Oracle Support Password is specified
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false

#Provide the Proxy Host
PROXY_HOST=

#Provide the Proxy Port
PROXY_PORT=

#Provide the Proxy Username
PROXY_USER=

#Provide the Proxy Password
PROXY_PWD=<SECURE VALUE>

#Type String (URL format) Indicates the OCM Repeater URL which should be of the format [scheme[Http/Https]]://[repeater host]:[repeater port]
COLLECTOR_SUPPORTHUB_URL=


EOF
}

#Function to create Weblogic Uninstallation Response Template File for Silent Uninstallation
function create_oraUninstallResponseTemplate()
{
    echo "creating Uninstall Response Template..."

    cat <<EOF >$WLS_PATH/silent-template/uninstall-response.template
[ENGINE]

#DO NOT CHANGE THIS.
Response File Version=1.0.0.0.0

[GENERIC]

#This will be blank when there is nothing to be de-installed in distribution level
SELECTED_DISTRIBUTION=WebLogic Server~[WLSVER]

#The oracle home location. This can be an existing Oracle Home or a new Oracle Home
ORACLE_HOME=[INSTALL_PATH]/oracle/middleware/oracle_home/

EOF
}

#Install Weblogic Server using Silent Installation Templates
function installWLS()
{
    # Using silent file templates create silent installation required files
    echo "Creating silent files for installation from silent file templates..."

    sed 's@\[INSTALL_PATH\]@'"$INSTALL_PATH"'@' ${SILENT_FILES_DIR}/uninstall-response.template > ${SILENT_FILES_DIR}/uninstall-response
    sed -i 's@\[WLSVER\]@'"$WLS_VER"'@' ${SILENT_FILES_DIR}/uninstall-response
    sed 's@\[INSTALL_PATH\]@'"$INSTALL_PATH"'@' ${SILENT_FILES_DIR}/response.template > ${SILENT_FILES_DIR}/response
    sed 's@\[INSTALL_PATH\]@'"$INSTALL_PATH"'@' ${SILENT_FILES_DIR}/oraInst.loc.template > ${SILENT_FILES_DIR}/oraInst.loc
    sed -i 's@\[GROUP\]@'"$USER_GROUP"'@' ${SILENT_FILES_DIR}/oraInst.loc

    echo "Created files required for silent installation at $SILENT_FILES_DIR"

    export UNINSTALL_SCRIPT=$INSTALL_PATH/oracle/middleware/oracle_home/oui/bin/deinstall.sh
    if [ -f "$UNINSTALL_SCRIPT" ]
    then
            currentVer=`. $INSTALL_PATH/oracle/middleware/oracle_home/wlserver/server/bin/setWLSEnv.sh 1>&2 ; java weblogic.version |head -2`
            echo "#########################################################################################################"
            echo "Uninstalling already installed version :"$currentVer
            runuser -l oracle -c "$UNINSTALL_SCRIPT -silent -responseFile ${SILENT_FILES_DIR}/uninstall-response"
            sudo rm -rf $INSTALL_PATH/*
            echo "#########################################################################################################"
    fi

    echo "---------------- Installing WLS ${WLS_JAR} ----------------"
    
    
    if [[ "$jdkversion" =~ ^jdk1.8* ]]
    then
    
    echo $JAVA_HOME/bin/java -d64  -jar  ${WLS_JAR} -silent -invPtrLoc ${SILENT_FILES_DIR}/oraInst.loc -responseFile ${SILENT_FILES_DIR}/response -novalidation
    runuser -l oracle -c "$JAVA_HOME/bin/java -d64 -jar  ${WLS_JAR} -silent -invPtrLoc ${SILENT_FILES_DIR}/oraInst.loc -responseFile ${SILENT_FILES_DIR}/response -novalidation"
    
    else 

    echo $JAVA_HOME/bin/java -jar  ${WLS_JAR} -silent -invPtrLoc ${SILENT_FILES_DIR}/oraInst.loc -responseFile ${SILENT_FILES_DIR}/response -novalidation
    runuser -l oracle -c "$JAVA_HOME/bin/java -jar  ${WLS_JAR} -silent -invPtrLoc ${SILENT_FILES_DIR}/oraInst.loc -responseFile ${SILENT_FILES_DIR}/response -novalidation"
    
    fi

    # Check for successful installation and version requested
    if [[ $? == 0 ]];
    then
      echo "Weblogic Server Installation is successful"
    else

      echo_stderr "Installation is not successful"
      exit 1
    fi
    echo "#########################################################################################################"

}

# Update the RHEL OS to latest
function updateRHELOS()
{
	echo "Locking version to linux version : $linuxversion"
	echo "Kernel version before update:"
	uname -a
	if [ "$linuxversion" == "7.3" ]
	then
    	sudo yum clean all
    	sudo yum makecache
    	echo "Enable repos : --disablerepo='*' --enablerepo='*microsoft*'"
    	sudo yum update -y --disablerepo='*' --enablerepo='*microsoft*'
	fi
	
	echo "Disable non-EUS repos : --disablerepo='*' remove 'rhui-azure-rhel7'"
	sudo yum -y --disablerepo='*' remove 'rhui-azure-rhel7'
	echo "Add EUS repos:https://rhelimage.blob.core.windows.net/repositories/rhui-microsoft-azure-rhel7-eus.config" 
	sudo yum -y --config='https://rhelimage.blob.core.windows.net/repositories/rhui-microsoft-azure-rhel7-eus.config' install 'rhui-azure-rhel7-eus'
	echo "Lock the releasever variable "
	sudo echo $(. /etc/os-release && echo $VERSION_ID) > /etc/yum/vars/releasever
	sudo cat /etc/yum/vars/releasever
	echo "Update RHEL VM"
	sudo yum -y update
	echo "Kernel version after update:"
	uname -a	
}

#Update the Oracle Linux to latest
function updateOLOS()
{
	osVersion=`cat /etc/os-release | grep VERSION_ID |cut -f2 -d"="| sed 's/\"//g'`
	majorVersion=`echo $osVersion |cut -f1 -d"."`
	minorVersion=`echo $osVersion |cut -f2 -d"."`
	echo "Kernel version before update:"
	uname -a
	echo yum upgrade -y --disablerepo=ol7_latest  --enablerepo=ol${majorVersion}_u${minorVersion}_base
	yum upgrade -y --disablerepo=ol7_latest  --enablerepo=ol${majorVersion}_u${minorVersion}_base
	echo "Kernel version after update:"
	uname -a
}

# Update th opatch utility as per opatchURL supplied
function opatchUpdate()
{
	if [ $opatchURL != "none" ];
	then
		sudo mkdir -p ${opatchWork}
		filename=${opatchURL##*/}
		downloadUsingWget "$opatchURL"
		
		echo "Verifying the ${filename} patch download"
		ls  $filename
		checkSuccess $? "Error : Downloading ${filename} patch failed"
		
		cd ${opatchWork}
		echo "Opatch version before updating patch"
		runuser -l oracle -c "$oracleHome/OPatch/opatch version"
		unzip $filename
		opatchFileName=`find . -name opatch_generic.jar`
		command="java -jar ${opatchFileName} -silent oracle_home=$oracleHome"
		sudo chown -R $username:$groupname ${opatchWork}
		echo "Executing optach update command:"${command}
		runuser -l oracle -c "cd $oracleHome/wlserver/server/bin ; . ./setWLSEnv.sh ;cd ${opatchWork}; ${command}"
		checkSuccess $? "Error : Updating opatch failed"
		echo "Opatch version after updating patch"
		runuser -l oracle -c "$oracleHome/OPatch/opatch version"
	fi
}


function wlspatchUpdate()
{
	if [ $wlspatchURL != "none" ];
	then
		downloadUsingWget "$wlspatchURL"
		sudo mkdir -p ${wlsPatchWork}
		cd ${wlsPatchWork}
		echo "WLS patch details before applying patch"
		runuser -l oracle -c "$oracleHome/OPatch/opatch lsinvetory"
		filename=${wlspatchURL##*/}
		unzip $filename
		sudo chown -R $username:$groupname ${wlsPatchWork}
		sudo chmod -R 755 ${wlsPatchWork}
		#Check whether it is bundle patch
		patchListFile=`find . -name linux64_patchlist.txt`
		if [[ "${patchListFile}" == *"linux64_patchlist.txt"* ]]; 
		then
			echo "Applying WebLogic Stack Patch Bundle"
			command="${oracleHome}/OPatch/opatch napply -silent -oh ${oracleHome}  -phBaseFile linux64_patchlist.txt"
			echo $command
			runuser -l oracle -c "cd ${wlsPatchWork}/*/binary_patches ; ${command}"
			checkSuccess $? "Error : WebLogic patch update failed"
		else
			echo "Applying regular WebLogic patch"
			command="${oracleHome}/OPatch/opatch apply -silent"
			echo $command
			runuser -l oracle -c "cd ${wlsPatchWork}/* ; ${command}"
			checkSuccess $? "Error : WebLogic patch update failed"
		fi
		echo "WLS patch details after applying patch"
		runuser -l oracle -c "$oracleHome/OPatch/opatch lsinventory"
	fi
}

#main script starts here

CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export BASE_DIR="$(readlink -f ${CURR_DIR})"

if [ $# -ne 10 ]
then
    usage
    exit 1
fi

export acceptOTNLicenseAgreement="$1"
export otnusername="$2"
export otnpassword="$3"
export shiphomeurl="$4"
export jdkurl="$5"
export wlsversion="$6"
export jdkversion="$7"
export linuxversion="$8"
export opatchURL="$9"
export wlspatchURL="${10}"
export WLS_VER=$wlsversion
export WEBLOGIC_DEPLOY_TOOL=https://github.com/oracle/weblogic-deploy-tooling/releases/download/weblogic-deploy-tooling-1.8.1/weblogic-deploy.zip
export POSTGRESQL_JDBC_DRIVER_URL=https://jdbc.postgresql.org/download/postgresql-42.3.6.jar
export POSTGRESQL_JDBC_DRIVER=${POSTGRESQL_JDBC_DRIVER_URL##*/}
export MSSQL_JDBC_DRIVER_URL=https://repo.maven.apache.org/maven2/com/microsoft/sqlserver/mssql-jdbc/10.2.1.jre8/mssql-jdbc-10.2.1.jre8.jar
export MSSQL_JDBC_DRIVER=${MSSQL_JDBC_DRIVER_URL##*/}
export oracleHome="/u01/app/wls/install/oracle/middleware/oracle_home"
export opatchWork="/u01/app/opatch"
export wlsPatchWork="/u01/app/wlspatch"

if [ -z "$acceptOTNLicenseAgreement" ];
then
        echo _stderr "acceptOTNLicenseAgreement is required. Value should be either Y/y or N/n"
        exit 1
fi

if [[ ! ${acceptOTNLicenseAgreement} =~ ^[Yy]$ ]];
then
    echo "acceptOTNLicenseAgreement value not specified as Y/y (yes). Exiting installation Weblogic Server process."
    exit 1
fi

if [[ -z "$otnusername" || -z "$otnpassword" ]]
then
        echo_stderr "otnusername or otnpassword is required. "
        exit 1
fi

if [[ -z "$linuxversion" ]]
then
	echo_stderr "Linux version is required"
	exit 1
fi

# Verify whether OS is Oracle Linux or RHEL
export osName=`hostnamectl | grep CPE |awk '{print $4}'`

if [[ $osName == *"oracle"* ]]; then
	echo "Oracle OS selected"
else
	echo "RHEL OS and need to perform some disk operations"
	export SWAP_FILE_DIR="/mnt"
	export SWAP_FILE="$SWAP_FILE_DIR/swapfile"
	# Resize the disk if / disk space is less than rootDiskSizeLimit
	export rootDiskSizeLimit="6"
	
	# Reszing the "/" file system size as it is having only 2GB space
	# if "/" file system disk is less than rootDiskSizeLimit then resize it
	diskSize=`df -hP / | awk '{print $2}' |tail -1|sed 's/G//g'`
	diskSize=${diskSize%.*}
	if [ "$diskSize" -lt "$rootDiskSizeLimit" ]; then
	   echo "'/' file system has less space $diskSize GB , attempting for resizing"
	   resizeDisk
	fi
	
	# mount the data disk for JDK and WLS setup
	# This has to run first as data disk is mounted /u01 directory
	#mountDataDisk
	
	# Create swap file, which is required for WLS installation
	createSwap
fi

#add oracle group and user
echo "Adding oracle user and group..."
groupname="oracle"
username="oracle"
user_home_dir="/u01/oracle"
USER_GROUP=${groupname}
sudo groupadd $groupname
sudo useradd -d ${user_home_dir} -m -g $groupname $username

if [ -d ${user_home_dir} ]
then
	echo "User home directory is created ${user_home_dir}"
else
	sudo mkdir -p ${user_home_dir}
	sudo chown -R $username:$groupname ${user_home_dir}
fi	

JDK_PATH="/u01/app/jdk"
WLS_PATH="/u01/app/wls"
WL_HOME="/u01/app/wls/install/oracle/middleware/oracle_home/wlserver"


#create custom directory for setting up wls and jdk
sudo mkdir -p $JDK_PATH
sudo mkdir -p $WLS_PATH
sudo rm -rf $JDK_PATH/*
sudo rm -rf $WLS_PATH/*

cleanup

sudo mkdir -p ${user_home_dir}
sudo chown -R $username:$groupname ${user_home_dir}

#download jdk from OTN
echo "Downloading jdk from OTN..."
curl -s https://raw.githubusercontent.com/typekpb/oradown/master/oradown.sh  | bash -s -- --cookie=accept-weblogicserver-server --username="${otnusername}" --password="${otnpassword}" $jdkurl

#validateJDKZipCheckSum $BASE_DIR/jdk-8u131-linux-x64.tar.gz

#Download Weblogic install jar from OTN
echo "Downloading weblogic install kit from OTN..."
curl -s https://raw.githubusercontent.com/typekpb/oradown/master/oradown.sh  | bash -s -- --cookie=accept-weblogicserver-server --username="${otnusername}" --password="${otnpassword}" $shiphomeurl

#download Weblogic deploy tool 

sudo chown -R $username:$groupname /u01/app

sudo cp $BASE_DIR/fmw_*.zip $WLS_PATH/
sudo cp $BASE_DIR/jdk-*.tar.gz $JDK_PATH/

echo "extracting and setting up jdk..."
sudo tar -zxvf $JDK_PATH/jdk-*.tar.gz --directory $JDK_PATH
sudo chown -R $username:$groupname $JDK_PATH

export JAVA_HOME=$JDK_PATH/$jdkversion
export PATH=$JAVA_HOME/bin:$PATH

echo "JAVA_HOME set to $JAVA_HOME"
echo "PATH set to $PATH"

java -version

if [ $? == 0 ];
then
    echo "JAVA HOME set succesfully."
else
    echo_stderr "Failed to set JAVA_HOME. Please check logs and re-run the setup"
    exit 1
fi

if [[ $osName == *"oracle"* ]]; then

else

fi
echo "Installing zip unzip wget vnc-server rng-tools cifs-utils"
sudo yum install -y zip unzip wget vnc-server rng-tools cifs-utils cloud-utils-growpart gdisk psmisc util-linux

#Setting up rngd utils
sudo systemctl enable rngd 
sudo systemctl status rngd
sudo systemctl start rngd
sudo systemctl status rngd

echo "unzipping wls install archive..."
sudo unzip -o $WLS_PATH/fmw_*.zip -d $WLS_PATH

export SILENT_FILES_DIR=$WLS_PATH/silent-template
sudo mkdir -p $SILENT_FILES_DIR
sudo rm -rf $WLS_PATH/silent-template/*
sudo chown -R $username:$groupname $WLS_PATH

export INSTALL_PATH="$WLS_PATH/install"
export WLS_JAR=$WLS_PATH"/fmw_"$wlsversion"_wls.jar"

mkdir -p $INSTALL_PATH
sudo chown -R $username:$groupname $INSTALL_PATH

create_oraInstlocTemplate
create_oraResponseTemplate
create_oraUninstallResponseTemplate

installWLS

setupWDT

downloadJDBCDrivers

copyJDBCDriversToWeblogicClassPath

modifyWLSClasspath

testJDBCDrivers


#Update Opatch
opatchUpdate()
wlspatchUpdate()

if [[ $osName == *"oracle"* ]]; then
	updateOLOS()
else
	updateRHELOS
	#Disable swap created as it will be enabled by WALinux agent after reboot
	echo "Removing swap $SWAP_FILE"
	sudo swapoff $SWAP_FILE
	sudo swapon -s
fi

echo "Weblogic Server Installation Completed succesfully."


cleanup

echo "Removing history for oracle user"
runuser -l oracle -c "history -c && history -w && exit"
echo "Removing history for root user"
sudo history -c && history -w && exit
sudo reboot
