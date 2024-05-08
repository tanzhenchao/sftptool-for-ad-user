#!/bin/bash

source /etc/profile

config="/etc/sftp/sftptool.conf"
source "$config"

parameter1="$3"
parameter2="$4"
parameter3="$5"
parameter4="$6"

cd ~
if [ ! -d `dirname "$logAlert"` ]; then
	mkdir -p `dirname "$logAlert"`
fi
if [ ! -d `dirname "$logChange"` ]; then
	mkdir -p `dirname "$logChange"`
fi
if [ ! -d `dirname "$logMessage"` ]; then
	mkdir -p `dirname "$logMessage"`
fi

nowTime=`date '+%Y-%m-%d %H:%M:%S'`

checkJrRule() {
	jrNumber="`echo "$1" | tr 'a-z' 'A-Z'`"
	if [[ "$jrNumber" =~ ^(D2|CA|HK)[0-9]{4}[0-9]{2}[0-9]{2}(JR)[0-9]{4}$ ]]; then
		return 0
	else
		return 1
	fi
}

checkMailRule() {	
	if [[ "$1" == ?*@?*.?* ]]; then
		return 0
	else
		return 1
	fi
}

loginCheck() {
	userName="$1"

	## Refresh the user's cache data
	sss_cache -E

	## Determine if it is a valid user
	id "$userName" &> /dev/null
	if [ "$?" -ne "0" ]; then
		changeMsg="The system cannot find the user '$userName'."
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" | tee -a "$logMessage"; fi
		return 1
	fi

	## If it is a system user with a UID less than 1000, the program exits
	userUid=$(id -u "$userName")
	if [ "$userUid" -lt "1000" ]; then
		changeMsg="System user '"$userName"' with UID less than 1000 is not allowed to login."
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" | tee -a "$logMessage"; fi
		return 1
	fi

	## Check if the user is a domain user, otherwise exit
	if [ `id "$userName" | grep "domain users" | wc -l` -eq 0 ]; then
		changeMsg="Non-domain user '"$userName"' is not allowed to login."
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" | tee -a "$logMessage"; fi
		return 1
	fi
	return 0
}

userFormat() {
	userName="$1"

	## Determine if the input username format meets the requirements, otherwise exit
	formatMark=0
	echo "$userName" | egrep '.*@.*' &> /dev/null
	if [ "$?" -eq "0" ]; then
		formatMark=1
	fi
	echo "$userName" | egrep '.*\\.*' &> /dev/null
	if [ "$?" -eq "0" ]; then
		formatMark=2
	fi
	if [ "$formatMark" -eq "0" ]; then
		changeMsg="The login user '"$userName"' account format does not meet the requirements."
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" | tee -a "$logMessage"; fi
		return 1
	fi

	## Convert the input username format to the standard format
	userName="$(echo $userName | awk '{print tolower($0)}')"
	if [ "$formatMark" -eq "2" ]; then
		userName="$(echo "$userName" | awk -F '\' '{print $2"@"$1}')"
	fi
	echo "$userName"
	return 0
}

addShareFile() {
	sftpAccountName="$(userFormat $parameter1)"

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
        if [ -f "$sftpUserRootDir"'/'"$shareFileName" ]; then
                return 0
        fi

	cat > "$sftpUserRootDir"'/'"$shareFileName" <<-EOF
	# The current configuration file is used to set up the sharing of your "/myhome" directory with other sftp accounts to allow them to add, delete, modify and query your data.
	# The configuration file will grant the corresponding permissions according to your current configuration after the user logs in again.

	# PERMISSION MODE:
	# - "rw" means that other sftp accounts are allowed to read, write and delete the contents of your shared directory.
	# - "ro" means that other sftp accounts are only allowed to read the contents of your directory and are not allowed to modify or delete them.

	# USE STEPS:
	# Step1. Download the current example file to your local computer.
	# Step2. Modify the configuration file according to the example.
	# Step3. Upload and replace the current configuration.

	# Example:
	# cmdschool.org\will rw
	# cmdschool.com\jeff ro

	# NOTE:
	# The content after the "#" symbol at the beginning of each line is a comment, so please do not include "#" symbols at the beginning of the configuration.
	EOF
        chown "$sftpAccountName":"$domainGroupName" "$sftpUserRootDir"'/'"$shareFileName"
        chmod 600 "$sftpUserRootDir"'/'"$shareFileName"
	changeMsg='addShareFile "'"jr:$jrNumber account:$sftpAccountName"'"'
	if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
}

addUser() {
	# Function implementation to add sftp new user.
	if [ "$parameter1" == "" ] || [ "$parameter2" == "" ]; then
		echo "Usage: $0 user add <example.com\loginName> <JR No.> [user passwd]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	sftpPasswd="$parameter3"

	addLdapUserStatus="false"
	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		userDomain=$(echo $sftpAccountName | cut -d "@" -f2)
		if [ "${ldap[$userDomain.Editable]}" == "true" ]; then
			addLdapUserStatus="true"
		else
			echo "Please create an AD user first"
			exit 1
		fi
	else
		userDomain=$(echo $sftpAccountName | cut -d "@" -f2)
	fi
	userName=$(echo $sftpAccountName | cut -d "@" -f1)

        sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	if [ "$addLdapUserStatus" == "true" ]; then
		read -p 'Please enter the mail address of user "'"$userName"'" :' userMail
	else
		userMail=`$0 ldap get userInfo "$sftpAccountName" "mail" | sed 's/mail: //g'`
		if [ "$userMail" == "" ]; then
			echo 'Please set email address for the domain user first!'
			exit 1
		fi
	fi
	if ! checkMailRule "$userMail"; then
		echo 'The format of the automatically obtained mail "'"$userMail"'" address is abnormal!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1
	fi

	echo '#------------------------------------------------'
	echo 'End User Staff: '"$sftpAccountName"
	echo 'End User Mail: '"$userMail"
	echo 'JR: '"$jrNumber"
	echo 'SFTP Account: '"$sftpAccountName"
	for ((;;)); do
		read -p 'Confirm user information, Continue (y/n)?' choice
		case "$choice" in 
			y|Y )
				echo "yes"
				break
		        	;;
			n|N )
				echo "no"
				exit 0
				;;
			* )
				echo "invalid!"
				;;
		esac
	done

	adminUserName=$(echo "${ldap[$userDomain.BindDN]}" | cut -d ',' -f1 | cut -d '=' -f2)
	if [ "$addLdapUserStatus" == "true" ]; then
		if [ "$sftpPasswd" == "" ]; then
			sftpPasswd=`mkpasswd-expect -l 10`
		fi
		echo "${ldap[$userDomain.Passwd]}" | adcli create-user -D "$userDomain" -U "$adminUserName" --mail="$userMail" --stdin-password "$userName"
	fi

	if [ $(id "$sftpAccountName" 2>&1 | grep "$sftpGroupName" | wc -l) == "0" ]; then
		echo "${ldap[$userDomain.Passwd]}" | adcli add-member -D "$userDomain" -U "$adminUserName" --stdin-password "$sftpGroupName" "$userName"
	fi

	$0 home add "$sftpAccountName" "$jrNumber"
	addShareFile "$sftpAccountName"
	for ((;;)); do
		echo ''
		echo '#------------------------------------------------'
		read -p "Please enter the space quota size requested by the user(default $defaultQuota):" quota
		$0 quota set "$sftpAccountName" "$jrNumber" "$quota"
		if [ $? = 0 ]; then
			break
		fi
	done
	$0 ca add "$sftpAccountName" "$jrNumber"

	expires=`date -d "+$defaultExpires day $nowTime" +"%Y-%m-%d %H:%M:%S"`
	echo 'staff: '"$sftpAccountName" > "$sftpUserInfo"
	echo 'mail: '"$userMail" >> "$sftpUserInfo"
	echo 'jr: '"$jrNumber" >> "$sftpUserInfo"
	echo 'ctime: '"$nowTime" >> "$sftpUserInfo"
	echo 'expires: '"$expires" >> "$sftpUserInfo"
	if [ "$addLdapUserStatus" == "true" ]; then
		$0 passwd reset "$sftpAccountName" "$jrNumber" "$sftpPasswd"
	fi
	/usr/bin/chmod 600 "$sftpUserInfo"

        if [ `id "$sftpAccountName" 2>&1 | grep "no such user" | wc -l` == 1 ]; then
		echo 'User "'"$sftpAccountName"'" was created failed!'
		exit 1
	else
		echo 'User "'"$sftpAccountName"'" was created successfully!'
		changeMsg='addUser "''jr:'"$jrNumber"' account:'"$sftpAccountName"' staff:'"$sftpAccountName"' mail:'"$userMail"' expires:'"$expires"'"'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi
	echo ''
	echo 'User details see below,'
	echo '#------------------------------------------------'

	$0 user get "$sftpAccountName"
	echo ''
	echo '#------------------------------------------------'
	for ((;;)); do
		echo 'Please choose a login type,'
		read -p 'Continue with (k/K) for key file authentication or (p/P) for password authentication(default password): ' choice
		case "$choice" in
			k|K )
				loginType="keyfile"
				echo "Login Type: Key file"
				break
		        	;;
			p|P )
				loginType="password"
				echo "Login Type: Username and password"
				break
				;;
			"$Na" )
				loginType="password"
				echo "Login Type: Username and password"
				break
		        	;;
			* )
				echo "invalid!"
				;;
		esac
	done
	echo ''
	echo '#------------------------------------------------'
	for ((;;)); do
		if [ "$loginType" == "keyfile" ]; then
			read -p 'Send username and key file of "'"$sftpAccountName"'", Continue (y/n)?' choice
		else
			read -p 'Send username and password of "'"$sftpAccountName"'", Continue (y/n)?' choice
		fi
		case "$choice" in 
			y|Y )
				echo "yes"
				if [ "$loginType" == "keyfile" ]; then
					$0 ca send "$sftpAccountName"
				else
					$0 passwd send "$sftpAccountName"
				fi
				exit 0
		        	;;
			n|N )
				echo "no"
				exit 1
				;;
			* )
				echo "invalid!"
				;;
		esac
	done
}

getUser() {
	# Function implementation to get user list
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 user get <list>"
		echo "       $0 user get <example.com\loginName>"
		echo "       $0 user get <all>"
		echo "       $0 user get <root>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"
	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'

	if [ "$parameter1" == "root" ]; then
		$0 home get root
		$0 ca get root
	fi

	if [ "$parameter1" == "list" ]; then
		$0 ldap get sftpUsers cmdschool.org
		$0 ldap get sftpUsers cmdschool.com
	fi

	if [ "$parameter1" != "list" -a "$parameter1" != "all" -a "$parameter1" != "root" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		userInfo=""
		if [ -f "$sftpUserInfo" ]; then
			userInfo=`cat "$sftpUserInfo"`
		else
			echo 'Error: User information file '"$sftpUserInfo"' is lost, please fix it manually!'
		fi
		echo 'SFTP Account: '"$sftpAccountName"
		echo 'SFTP Account Create Time: '`echo "$userInfo" | grep "ctime: " | sed 's/ctime: //g'`
		echo 'End User Staff: '`echo "$userInfo" | grep "staff: " | sed 's/staff: //g'`
		echo 'End User Initial Mail: '`echo "$userInfo" | grep "mail: " | sed 's/mail: //g'`
		echo 'End User JR: '`echo "$userInfo" | grep "jr: " | sed 's/jr: //g'`
		echo 'User OS ID: '`id "$sftpAccountName"`
		echo 'User Data Root: '"$sftpUserRootDir"
		echo 'User Home: '"$sftpUserHomeDir"
		$0 ca get "$sftpAccountName"
		$0 quota get "$sftpAccountName"
	fi

	if [ "$parameter1" == "all" ]; then
		for i in $($0 user get list); do
			$0 user get "$i"
			echo
		done
	fi
}

delUser() {
	# Function to delete user
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 user del <example.com\loginName> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	 fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	if [ ! -f "$sftpUserInfo" ]; then
		echo 'Could not find user user info file: '"$sftpUserInfo"
		exit 1
	fi
	endUserStaffNumber=`cat "$sftpUserInfo" | grep "staff: " | sed 's/staff: //g'`
	userMail=`cat "$sftpUserInfo" | grep "mail: " | sed 's/mail: //g'`
	ctime=`cat "$sftpUserInfo" | grep "ctime: " | sed 's/ctime: //g'`
	expires=`cat "$sftpUserInfo" | grep "expires: " | sed 's/expires: //g'`

	if [ `pgrep -u "$sftpAccountName" sshd | wc -l` != 0 ]; then
		echo ''
		echo '#------------------------------------------------'
		for ((;;)); do
			read -p 'User "'$sftpAccountName'" is still online, Continue (y/n)?' choice
			case "$choice" in
				y|Y )
					echo "yes"
					break
					;;
				n|N )
					echo "no"
					exit 1
					;;
				* )
					echo "invalid!"
					;;
			esac
		done
	fi
	echo ''
	echo '#------------------------------------------------'
	$0 ca del "$sftpAccountName" "$jrNumber"
	if [ -d "$sftpUserKeysRootDir" ]; then
		rm -rf "$sftpUserKeysRootDir"
	fi
	echo ''
	echo '#------------------------------------------------'
	$0 home del "$sftpAccountName" "$jrNumber"
	for ((;;)); do
		echo ''
		echo '#------------------------------------------------'
		read -p 'Remove AD user "'$sftpAccountName'" from Group "'$sftpGroupName'", Continue (y/n)?' choice
		case "$choice" in 
			y|Y )
				echo "yes"
				userDomain=$(echo $sftpAccountName | cut -d "@" -f2)
				if [ $(id "$sftpAccountName" 2> /dev/null | grep "$sftpGroupName" | wc -l) != "0" ]; then
					adminUserName=$(echo "${ldap[$userDomain.BindDN]}" | cut -d ',' -f1 | cut -d '=' -f2)
					userName=$(echo $sftpAccountName | cut -d "@" -f1)
					echo "${ldap[$userDomain.Passwd]}" | adcli remove-member -D "$userDomain" -U "$adminUserName" --stdin-password "$sftpGroupName" "$userName"
				fi
				sss_cache -E
				echo 'Successfully!'
				changeMsg='delGroupMember "''jr:'"$jrNumber"' account:'"$sftpAccountName"' staff:'"$endUserStaffNumber"' mail:'"$userMail"' ctime:'"$ctime"' expires:'"$expires"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
				break
		        	;;
			n|N )
				echo "no"
				break
				;;
			* )
				echo "invalid!"
				continue
				;;
		esac
	done
	if [ "${ldap[$userDomain.Editable]}" == "false" ]; then
		for ((;;)); do
			if [ `pgrep -u "$sftpAccountName" sshd | wc -l` != 0 ]; then
				for i in `pgrep -u "$sftpAccountName" sshd`; do kill $i; done
				sleep 0.1
			else
				exit 0
			fi
		done
	fi
	for ((;;)); do
		echo ''
		echo '#------------------------------------------------'
		read -p 'Remove ad account of "'$sftpAccountName'", Continue (y/n)?' choice
		case "$choice" in 
			y|Y )
				echo "yes"
				for ((;;)); do
					if [ `pgrep -u "$sftpAccountName" sshd | wc -l` != 0 ]; then
						for i in `pgrep -u "$sftpAccountName" sshd`; do kill $i; done
						sleep 0.1
					else
						break
					fi
				done
				userDomain=$(echo $sftpAccountName | cut -d "@" -f2)
				adminUserName=$(echo "${ldap[$userDomain.BindDN]}" | cut -d ',' -f1 | cut -d '=' -f2)
				userName=$(echo $sftpAccountName | cut -d "@" -f1)
				echo "${ldap[$userDomain.Passwd]}" | adcli delete-user -D "$userDomain" -U "$adminUserName" --stdin-password "$userName"
				sss_cache -E
				echo 'Successfully!'
				changeMsg='delUser "''jr:'"$jrNumber"' account:'"$sftpAccountName"' staff:'"$endUserStaffNumber"' mail:'"$userMail"' ctime:'"$ctime"' expires:'"$expires"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
				break
		        	;;
			n|N )
				echo "no"
				exit 1
				;;
			* )
				echo "invalid!"
				continue
				;;
		esac
	done
	return 0
}

resetUserPasswd() {
	#Function to add user password
	if [ "$parameter1" == "" ] || [ "$parameter2" == "" ]; then
		echo "Usage: $0 user add <example.com\loginName> <JR No.> [sftp passwd]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	sftpPasswd="$parameter3"

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"

	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1
	fi

        sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	userDomain=$(echo $sftpAccountName | cut -d "@" -f2)
	userName=$(echo $sftpAccountName | cut -d "@" -f1)
	if [ "${ldap[$userDomain.Editable]}" = "false" ]; then
		echo 'Password of domain user "'"$sftpAccountName"'" is not allow modifiled!'
		exit 1
	fi

	if [ "$sftpPasswd" == "" ]; then
		sftpPasswd=`mkpasswd-expect -l 10`
	fi
	adminUserName=$(echo "${ldap[$userDomain.BindDN]}" | cut -d ',' -f1 | cut -d '=' -f2)
	expect <<-EOF
	spawn adcli passwd-user -D "$userDomain" -U "$adminUserName" "$userName"
	expect "Password"
	send "${ldap[$userDomain.Passwd]}\r"
	expect "Password"
	send "${sftpPasswd}\r"
	expect eof	
	EOF

	userPasswordSave=`cat "$sftpUserInfo" | grep "userInitialPassword: " | sed 's/userInitialPassword: //g'`
	sftpPasswdSave=`echo "$sftpPasswd" | base64 -i`
	if [ "$userPasswordSave" == "" ]; then
		echo 'userInitialPassword: '"$sftpPasswdSave" >> "$sftpUserInfo"
	else
		sed -i "s/$userPasswordSave/$sftpPasswdSave/g" "$sftpUserInfo"		
	fi

	userPasswordSave=`cat "$sftpUserInfo" | grep "userInitialPassword: " | sed 's/userInitialPassword: //g'`
        if [ "$userPasswordSave" == "" ]; then
		echo 'User "'"$sftpAccountName"'" password was created failed!'
		exit 1
	else
		echo 'User "'"$sftpAccountName"'" password was created successfully!'
		changeMsg='addUserPasswd "''jr:'"$jrNumber"' account:'"$sftpAccountName"' userPassword:******'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi

}

sendUserPasswd() {
	#Function to send user password to user
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 passwd send <example.com\loginName> [userName] [userMail]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpUserName="$parameter2"
	sftpUserMail="$parameter3"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	if [ ! -f "$sftpUserInfo" ]; then
		echo 'Could not find user user info file: '"$sftpUserInfo"
		exit 1
	fi

	sftpUserMail=`cat "$sftpUserInfo" | grep "mail: " | sed 's/mail: //g'`
	if [ "$sftpUserMail" == "" ]; then
		read -p 'Please enter email address of account "'"$sftpAccountName"'": ' mailTo
	else
		mailTo="$sftpUserMail"
	fi
	if ! checkMailRule "$mailTo"; then
		echo 'Email address "'$mailTo'" does not meet the rules!'
		exit 1
	fi

	jrNumber=`cat "$sftpUserInfo" | grep "jr: " | sed 's/jr: //g'`
	if [ "$jrNumber" == "" ]; then
		read -p 'Please enter JR Number of user "'"$sftpAccountName"'": ' var
		jrNumber="`echo $var | tr 'a-z' 'A-Z'`"
	fi
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1
	fi
	endUserStaffNumber=`cat "$sftpUserInfo" | grep "staff: " | sed 's/staff: //g'`
	userName=`$0 ldap get userInfo "$endUserStaffNumber" cn | grep "cn: " | sed 's/cn: //g'`
	userPasswordSave=`cat "$sftpUserInfo" | grep "userInitialPassword: " | sed 's/userInitialPassword: //g'`

	if [ "$userName" == "" ]; then
		read -p 'Please enter user name of user "'"$sftpAccountName"'": ' var
		userName="`echo $var | tr 'a-z' 'A-Z'`"
	fi

	userDomain=$(echo $sftpAccountName | cut -d "@" -f2)
	if [ "${ldap[$userDomain.Editable]}" = "true" ]; then
		userPassword=`echo "$userPasswordSave" | base64 -d`
		$0 ldap check "$sftpAccountName"
		if [ "$?" != "0" ]; then
			echo 'Sending User "'"$sftpAccountName"'" password not match ldap password, please update and tryi again!'
			exit 1
		fi
	else
		userPassword='<Computer Login Password>'
	fi

	echo ''
	echo '#------------------------------------------------'
	echo 'End User Name: '"$userName"
	echo 'End User Mail: '"$mailTo"
	echo 'JR: '"$jrNumber"
	echo 'SFTP Account: '"$sftpAccountName"
	for ((;;)); do
		read -p 'Confirm user information, Continue (y/n)?' choice
		case "$choice" in 
			y|Y )
				echo "yes"
				break
		        	;;
			n|N )
				echo "no"
				exit 1
				;;
			* )
				echo "invalid!"
				;;
		esac
	done

	mailSubject='[CMDSCHOOL SFTP] SFTP account is ready – ['"$jrNumber"']'
	cat <<-EOF | mail -s "$mailSubject" -r "$mailFrom" "$mailTo"
	Dear $userName

	The SFTP account has been successfully created with the JR:$jrNumber. Please use the below username and password for SFTP services and keep confidential.

	Username: $(echo "$sftpAccountName" | awk -F '@' '{print $2 "\\" $1}')
	Password: $userPassword

	Please refer to the detailed User Guide below.

	https://pvtcloud.cmdschool.org/index.php/s/dx7ry7LFaStADDc

	You may contact IT HelpDesk, if you need further assistance or queries. 
	IT Helpdesk: (xx) xxxx

	Note: This email is an automatically generated email from [CMDSCHOOL SFTP], please do not respond to this email, and delete immediately after saving the credentials!

	EOF
	if [ "$?" == "0" ]; then
		echo "successfully!"
		changeMsg='sendUserPasswd "''jr:'"$jrNumber"' account:'"$sftpAccountName"' userTo:'"$userName"' mailTo:'"$mailTo"'"'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi
	return 0
}

addUserHome() {
	# Function to create user home directory
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 home add <example.com\loginName> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"

        if [ -d "$sftpUserRootDir" ]; then
		echo 'The user "'"$sftpAccountName"'" directory already exists, please backup and remove it first!'
		echo "$sftpUserRootDir"
		exit 1;
	fi

	mkdir -p "$sftpUserHomeDir"
	chown root:root "$sftpUserRootDir"
	chmod -R 755 "$sftpUserRootDir"
	chown "$sftpAccountName":"$domainGroupName" "$sftpUserHomeDir"
	chmod -R 775 "$sftpUserHomeDir"
        if [ -d $sftpUserHomeDir ]; then
		changeMsg='addUserHome "''jr:'"$jrNumber"' account:'"$sftpAccountName"' home:'"$sftpUserHomeDir"'"'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi
}

delUserHome() {
	# Function to delete the user's home directory
	if [[ "$parameter1" == "" || "$parameter1" == "" ]]; then
		echo "Usage: $0 home del <example.com\loginName> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

        if [ ! -d "$sftpUserRootDir" ]; then
		echo 'The directory of user "'"$sftpAccountName"'" not found, the program exits!'
		exit 1;
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	read -p 'Remove directory of "'"$sftpUserRootDir"'", Continue (y/n)?' choice
	case "$choice" in 
		y|Y )
			echo "yes"
			$0 share del "$sftpAccountName" all "$jrNumber"
			if [ -f "$mailBox"'/'"$sftpAccountName" ]; then
				rm -f "$mailBox"'/'"$sftpAccountName"
			fi
			if [ -d "$sftpUserRootDir" ]; then
				rm -rf "$sftpUserRootDir"
			fi
        		if [ -d "$sftpUserRootDir" ]; then
				echo 'Failed, please try again!'
				exit 1
			else
                		echo 'Successfully!'
				changeMsg='delUserHome "''jr:'"$jrNumber"' account:'"$sftpAccountName"' root:'"$sftpUserRootDir"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
				return 0
        		fi
		        ;;
		n|N )
			echo "no"
			exit 1
			;;
		* )
			echo "invalid!"
			exit 1
			;;
	esac
}

getUserHome() {
	# Function implementation to query user home directory
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 home get <list>"
		echo "       $0 home get <example.com\loginName>"
		echo "       $0 home get <all>"
		echo "       $0 home get <root>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"

	if [ "$parameter1" == "root" ]; then
		echo 'Home Root Directory Path: '"$sftpDataDir"
		echo 'Home Root Directory Space: '`du -sh "$sftpDataDir" | awk  -F ' '  '{print $1}'`
	fi

	if [ "$parameter1" == "list" ]; then
		ls -d "$sftpDataDir"'/'*
	fi

	if [ "$parameter1" != "root" -a "$parameter1" != "list" -a "$parameter1" != "all" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		echo 'User Home Directory Path: '"$sftpUserHomeDir"
		echo 'User Home Directory Space: '`du -sh "$sftpUserHomeDir" | awk  -F ' '  '{print $1}'`
	fi

	if [ "$parameter1" == "all" ]; then
		for i in `$0 user get list`; do
			$0 home get "$i"
			echo
		done
	fi
}

addUserCA() {
	# Function to create a user's certificate.
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 ca add <example.com\loginName> <JR No.> [CA passwd]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	caPasswd="$parameter3"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'

        if [ -d "$sftpUserKeysDir" ]; then
                echo 'The user "'"$sftpUserKeysDir"'" authorized Keys directory already exists, please backup and remove it first!'
                echo "$sftpUserKeysDir"
                exit 1;
        fi

	mkdir -p "$sftpUserKeysDir"
	chown "$sftpAccountName":"$domainGroupName" "$sftpUserKeysDir"
	chmod 700 "$sftpUserKeysDir"
	cd "$sftpUserKeysDir"
	if [ "$caPasswd" == "" ]; then	
		ssh-keygen -t rsa -P "" -f "$sftpAccountName"'_rsa'
	else
		ssh-keygen -t rsa -P "$caPasswd" -f "$sftpAccountName"'_rsa'
	fi
	cat "$sftpAccountName"'_rsa.pub' > "$authorizedKeysName"
	chmod 600 "$authorizedKeysName"
	chown "$sftpAccountName":"$domainGroupName" "$authorizedKeysName"
	echo "$caPasswd" > old-passphrase
	puttygen --old-passphrase=old-passphrase -O private "$sftpAccountName"'_rsa' -o "$sftpAccountName"'_rsa.ppk'
	puttygen --old-passphrase=old-passphrase -O private "$sftpAccountName"'_rsa' -o "$sftpAccountName"'_rsa_v2.ppk' --ppk-param version=2
	rm -f old-passphrase
	echo 'Created successfully!'
	echo ''
	echo 'Certificate storage directory: '"$sftpUserKeysDir"
	echo 'Certificate name: '`ls "$sftpUserKeysDir"`
	echo ''
	echo 'Notice: '
	echo "$authorizedKeysName"' is the public key file authenticated by the sftp server (deleted users cannot login)'
	echo "$sftpAccountName"'.ppk is for the FileZilla client private key (should be sent to the user)'
	echo "$sftpAccountName"'_rsa is the private key for Linux sftp client (should be sent to the user)'
	echo "$sftpAccountName"'_rsa.pub is '"$authorizedKeysName"' file backup'
        if [ -f "$sftpUserKeysDir"'/'"$authorizedKeysName" ]; then
		changeMsg='addUserCA "''jr:'"$jrNumber"' account:'"$sftpAccountName"' ca:'"$sftpUserKeysDir"'/'"$authorizedKeysName"'"'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi
	return 0
}

delUserCA() {
	# Function to delete user certificate.
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 ca del <example.com\loginName> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi
        if [ -d "$sftpUserKeysRootDir" ]; then
		echo 'Certificate directory '"$sftpUserKeysRootDir"' does not exis!'
        fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'

	for ((;;)); do
		read -p 'Remove user certificate of "'"$sftpAccountName"'", Continue (y/n)?' choice
		case "$choice" in 
			y|Y )
				echo "yes"
        			if [ -d "$sftpUserKeysDir" ]; then
                			rm -rf "$sftpUserKeysDir"
        			fi
        			if [ -d "$sftpUserKeysDir" ]; then
					echo 'Failed, please try again!'
					break
				else
                			echo 'Successfully!'
					changeMsg='delUserCA "''jr:'"$jrNumber"' account:'"$sftpAccountName"' keyroot:'"$sftpUserKeysDir"'"'
					if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
					break
        			fi
		        	;;
			n|N )
				echo "no"
				break
				;;
			* )
				echo "invalid!"
				continue
				;;
		esac
	done
	return 0
}

resetUserCA() {
	#Function to delete the certificate and recreate it.
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 ca reset <example.com\loginName> <JR No.> [sftp passwd]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	sftpPasswd="$parameter3"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	$0 ca del "$sftpAccountName" "$jrNumber"
	if [ "$?" == "0" ]; then
		$0 ca add "$sftpAccountName" "$jrNumber" "$sftpPasswd"
	fi
}

getUserCA() {
	# Function implementation to get user certificate
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 ca get <list>"
		echo "       $0 ca get <example.com\loginName>"
		echo "       $0 ca get <all>"
		echo "       $0 ca get <root>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"
	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'

	if [ "$parameter1" == "root" ]; then
		echo 'Certificate Root Directory Path: '"$authorizedKeysRootDir"
		echo 'Certificate Root Directory Space: '`du -sh "$authorizedKeysRootDir" | awk  -F ' '  '{print $1}'`
	fi

	if [ "$parameter1" == "list" ]; then
		ls -d "$authorizedKeysRootDir"'/'*'/.ssh/'
	fi

	if [ "$parameter1" != "list" -a "$parameter1" != "root" -a "$parameter1" != "all" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		if [ -d "$sftpUserKeysDir" ]; then
			echo 'Certificate Storage Directory: '"$sftpUserKeysDir"
		else
			echo 'Error: SFTP user CA directory '"$sftpUserKeysDir"' is lost, please fix it manually!'
		fi
		$0 ca expire "$sftpAccountName"
		echo 'Authentication Public Key: '"$sftpUserKeysDir"'/'"$authorizedKeysName"
		echo 'Backup Public Key: '"$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa.pub'
		echo 'Linux SFTP Private Key: '"$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa'
		echo 'FileZilla Private Key: '"$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa.ppk'
		echo 'FileZilla Private Key Version 2: '"$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa_v2.ppk'
	fi

	if [ "$parameter1" == "all" ]; then
		for i in `$0 user get list`; do
			$0 ca get "$i"
			echo
		done
	fi
}

expireUserCA() {
	# Function to realize user certificate expiration date management
	if [[ "$parameter1" == "" || "$parameter2" == "+"* || "$parameter2" == "-"* ]]; then
		if [[ "$parameter1" == "" || "$parameter3" == "" ]]; then
			echo "Usage: $0 ca expire <example.com\loginName>"
			echo "       $0 ca expire <example.com\loginName> <+integer> <JR No.>"
			echo "       $0 ca expire <example.com\loginName> <-integer> <JR No.>"
			echo "       $0 ca expire <example.com\loginName> <check>"
			echo "       $0 ca expire <example.com\loginName> <flush>"
			echo "       $0 ca expire <all> <check>"
			echo "       $0 ca expire <all> <flush>"
			exit 1;
		fi
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpCMD="$parameter2"
	jrNumber="$parameter3"

	if [ "$sftpAccountName" != "all" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"
	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	userInfo=""
	if [ "$parameter1" != "all" ]; then
		if [ -f "$sftpUserInfo" ]; then
			userInfo=`cat "$sftpUserInfo"`
		else
			echo 'Error: User information file '"$sftpUserInfo"' is lost, please fix it manually!'
		fi
	fi
	infoExpires=`echo "$userInfo" | grep "expires: " | sed 's/expires: //g'`
	infoJrNumber=`echo "$userInfo" | grep "jr: " | sed 's/jr: //g'`
	infoEndUserStaffNumber=`echo "$userInfo" | grep "staff: " | sed 's/staff: //g'`
	infoUserMail=`echo "$userInfo" | grep "mail: " | sed 's/mail: //g'`

	formatNow=`date -d "$nowTime" +%s`
	formatExpires=`date -d "$infoExpires" +%s`
	expireDays="$((($formatExpires - $formatNow)/86400))"


	# show user ca expire
	if [[ "$parameter1" != "all" && "$parameter2" == "" && "$parameter2" != "+"* && "$parameter2" != "-"* ]]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		if [ ! -d "$sftpUserKeysDir" ]; then
			echo 'Error: SFTP user CA directory '"$sftpUserKeysDir"' is lost, please fix it manually!'
		fi
		echo 'Certificate Expires: '"$infoExpires"
	fi

	# edit user ca expire
	if [[ "$parameter1" != "all" && "$parameter2" == "+"* || "$parameter2" == "-"* ]]; then
		userMail=`$0 ldap get userInfo "$sftpAccountName" "mail" | sed 's/mail: //g'`
		abnormal="0"	
		if ! checkMailRule "$userMail"; then
			echo 'The format of the automatically obtained mail '"$userMail"' address is abnormal!'
			abnormal="1"
		fi
		if [ "$abnormal" == "1" ]; then
			read -p 'Please enter the mail address of user "'"$sftpAccountName"'" :' userMail
		fi
		if ! checkMailRule "$userMail"; then
			echo 'Email address "'$userMail'" does not meet the rules!'
			exit 1
		fi
		jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
		if ! checkJrRule "$jrNumber"; then
			echo 'JR number "'$jrNumber'" does not meet the rules!'
			exit 1;
		fi

		if [ "$infoJrNumber" = "$jrNumber" ]; then
			echo 'JR number "'$jrNumber'" already exists, the operation is canceled!'
			exit 1
		fi
		sed -i "s/$infoJrNumber/$jrNumber/g" "$sftpUserInfo"
		expireTime=`date -d "$infoExpire" +%s`
		currentTime=`date -d "$nowTime" +%s`
		if [ "$currentTime" -gt "$expireTime" -a "$sftpCMD"=="+" ]; then
			newExpires=`date -d "$sftpCMD day $nowTime" +"%Y-%m-%d %H:%M:%S"`
		else
			newExpires=`date -d "$sftpCMD day $infoExpires" +"%Y-%m-%d %H:%M:%S"`
		fi
		if [ "$infoExpires" != "$newExpires" ]; then
			sed -i "s/$infoExpires/$newExpires/g" "$sftpUserInfo"
		fi
		if [ "$infoEndUserStaffNumber" != "$sftpAccountName" ]; then
			sed -i "s/$infoEndUserStaffNumber/$sftpAccountName/g" "$sftpUserInfo"
		fi
		if [ "$infoUserMail" != "$userMail" ]; then
			sed -i "s/$infoUserMail/$userMail/g" "$sftpUserInfo"
		fi
		$0 ca expire "$sftpAccountName"
		changeMsg='expire-changeExpireUserCA "''jr:'"$jrNumber"' account:'"$sftpAccountName"' staff:'"$sftpAccountName"' mail:'"$userMail"' expires:'"$newExpires"'"'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi

	if [ "$parameter1" != "all" -a "$parameter2" == "check" ]; then
		if [ ! -f "$sftpUserInfo" ]; then
			echo 'Could not find user user info file: '"$sftpUserInfo"
			exit 1
		fi
		if [ "$expireDays" -gt "$alertDays" ]; then
			exit 0
		fi
		flag="0"
		for i in $(seq $alertDays -$alertFrequency $alertFrequency); do
			if [ "$expireDays" != "$i" ]; then
				continue
			fi
			flag="1"
		done
		senMsg='Send '"$expireDays"'-day extension notice to user '"$sftpAccountName"'.'
		if [ `egrep "$(date '+%Y-%m-%d')|$(date '+%Y-%m-%d' -d '-1 day')" "$logAlert" | grep "$senMsg" | wc -l` != "0" ]; then
			exit 0
		fi
		if [ "$flag" == "0" ]; then
			exit 0
		fi

		userName=`$0 ldap get userInfo "$infoEndUserStaffNumber" cn | grep "cn: " | sed 's/cn: //g'`
		ldapUserMail=`$0 ldap get userInfo "$infoEndUserStaffNumber" mail | grep "mail: " | sed 's/mail: //g'`

		if [ "$infoUserMail" == "$ldapUserMail" ]; then
			sftpUserMail="$infoUserMail"
		else
			sftpUserMail="$ldapUserMail"
		fi
		mailTo="$sftpUserMail"
		if ! checkMailRule "$mailTo"; then
			echo 'Email address "'$mailTo'" does not meet the rules!' | tee -a "$logMessage"
			exit 1
		fi
		if [ "$userName" == "" ]; then
			echo 'User Name "'$userName'" does not meet the rules!' | tee -a "$logMessage"
			exit 1
		fi

		mailSubject='[CMDSCHOOL SFTP] SFTP account extension notice'
		cat <<-EOF | mail -s "$mailSubject" -r "$mailFrom" "$mailTo"
		Dear $userName

		Your SFTP account "$sftpAccountName" will expiry on $infoExpires. Please submit IT JR for account renewal if necessary. Otherwise the account will be disabled without any further notice. Thanks!

		You may contact IT HelpDesk, if you need further assistance or queries. 
		IT Helpdesk: (xx) xxxx

		Note: This email is an automatically generated email from [CMDSCHOOL SFTP], please do not respond to this email.
		EOF
		if [ "$?" == "0" ]; then
			echo "$nowTime"' '"$senMsg" | tee -a "$logAlert"
			echo "successfully!"
			changeMsg='expire-sendAlertMail "''jr:'"$infoJrNumber"' account:'"$sftpAccountName"' userTo:'"$userName"' mailTo:'"$mailTo"' expiry:'"$infoExpires"'"'
			if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
		fi
		return 0
	fi

	if [ "$parameter1" == "all" -a "$parameter2" == "check" ]; then
		for i in `$0 user get list`; do
			$0 ca expire "$i" check
		done
	fi

	if [ "$parameter1" != "all" -a "$parameter2" == "flush" ]; then
		if [ "$formatNow" -ge "$formatExpires" ]; then
			flag=`grep ^# "$sftpUserKeysDir"'/'"$authorizedKeysName" | wc -l`
			if [ "$flag" != "0" ]; then
				echo 'No flush '"$sftpAccountName"'!'
				return 0
			fi
			sed -i "s/^/#/g" "$sftpUserKeysDir"'/'"$authorizedKeysName"
			flag=`grep ^# "$sftpUserKeysDir"'/'"$authorizedKeysName" | wc -l`
			if [ "$flag" != "0" ]; then
				echo 'Flush '"$sftpAccountName"', disable user CA!'
				changeMsg='expire-disableUserCA "''jr:'"$infoJrNumber"' account:'"$sftpAccountName"' expiry:'"$infoExpires"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
				return 0
			else
				echo 'Failed, please try again!'
				exit 1
			fi
		else
			flag=`grep ^# "$sftpUserKeysDir"'/'"$authorizedKeysName" | wc -l`
			if [ "$flag" == "0" ]; then
				echo 'No flush '"$sftpAccountName"'!'
				return 0
			fi
			sed -i "s/^#//g" "$sftpUserKeysDir"'/'"$authorizedKeysName"
			flag=`grep ^# "$sftpUserKeysDir"'/'"$authorizedKeysName" | wc -l`
			if [ "$flag" == "0" ]; then
				echo 'Flush '"$sftpAccountName"', enable User CA!'
				changeMsg='expire-enableUserCA "''jr:'"$infoJrNumber"' account:'"$sftpAccountName"' expiry:'"$infoExpires"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
				return 0
			else
				echo 'Failed, please try again!'
				exit 1
			fi
		fi

	fi

	if [ "$parameter1" == "all" -a "$parameter2" == "flush" ]; then
		for i in `$0 user get list`; do
			$0 ca expire "$i" flush
		done
	fi
}

setQuota() {
	# Function to realize user disk quota
	if [[ "$parameter1" == "" || "$parameter1" == "" ]]; then
		echo "Usage: $0 quota set <example.com\loginName> <JR No.> [quota]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"
	sftpQuota="$parameter3"


	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"

        if [ ! -d "$sftpUserRootDir" ]; then
		echo 'Please create user "'"$sftpAccountName"'" directory first,'
		echo "$sftpUserRootDir"
		exit 1;
	fi

	if [ "$sftpQuota" == "" ]; then
		sftpQuota="$defaultQuota"
	fi

	num=$(echo "$sftpQuota" | tr -cd '[0-9].')
	var=$(echo "$sftpQuota" | tr -d '[0-9].')
	case "$var" in
		[kK]|[kK][bB])
			sftpQuota=`echo "$num"`
			;;
		[mM]|[mM][bB])
			sftpQuota=`echo "$num * 1024" | bc`
		        ;;
		[gG]|[gG][bB])
			sftpQuota=`echo "$num * 1024 * 1024" | bc`
		        ;;
		[tT]|[tT][bB])
			sftpQuota=`echo "$num * 1024 * 1024 * 1024" | bc`
		        ;;
		*)
			echo "invalid!"
			exit 1
			;;
	esac
	setquota -u "$sftpAccountName" "$sftpQuota" "$sftpQuota" 0 0 "$quotaPath"
	changeMsg='setQuota "''jr:'"$jrNumber"' account:'"$sftpAccountName"' quota:'`echo "$sftpQuota / 1024 / 1024" | bc`'GB"'
	if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	getQuota "$sftpAccountName"
	return 0
}

getQuota() {
	# Function to realize user disk quota
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 quota get <all>"
		echo "       $0 quota get <example.com\loginName>"
		echo "       $0 quota get <root>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"

	if [ "$parameter1" == "root" ]; then
		mountDir="`df -h | grep $quotaPath | awk -F ' ' '{print $6}'`"
		echo 'Quota Root Directory: '"$quotaPath"
		echo 'Quota Root Directory Space: '`du -sh "$mountDir" | awk  -F ' '  '{print $1}'`
	fi

	if [ "$parameter1" != "root" -a "$parameter1" != "all" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi

        	if [ ! -d "$sftpUserRootDir" ]; then
			echo 'Please create user "'"$sftpAccountName"'" directory first,'
			echo "$sftpUserRootDir"
			exit 1;
		fi
		quotaMessage=`quota -u "$sftpAccountName" -s -w | grep $quotaPath`
		echo 'User Quota Directory: '"$sftpUserHomeDir"
		echo 'User Quota Space: '"`echo $quotaMessage | awk -F ' ' '{print $2}'`"
		echo 'User Quota: '"`echo $quotaMessage | awk -F ' ' '{print $3}'`"
		echo 'User Quota Limit: '"`echo $quotaMessage | awk -F ' ' '{print $4}'`"
	fi

	if [ "$parameter1" == "all" ]; then
		for i in `$0 user get list`; do
			$0 quota get "$i"
			echo
		done
	fi
}

setShare() {
	#The function realizes shareing a user's data directory to another user-specified directory
	if [[ "$parameter1" == "" || "$parameter2" == "" || "$parameter3" == "" ]]; then
		echo "Usage: $0 share set <from example.com\loginName> <share to example.com\loginName> <JR No.> [rw]"
		echo "       $0 share set <from example.com\loginName> <share to example.com\loginName> <JR No.> [ro]"
		exit 1;
	fi
	sftpAccountName="$(userFormat $parameter1)"
	sftpAccountNameShare="$(userFormat $parameter2)"
	jrNumber="$parameter3"
	writeEnable="$parameter4"

	loginCheck "$parameter1"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	loginCheck "$parameter2"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountNameShare"'" does not exist!'
		exit 1
	fi

        if [ "$parameter1" == "$parameter2" ]; then
		echo "Do not allow yourself to share yourself!"
		exit 1;
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"

        if [ ! -d "$sftpUserRootDir" ]; then
		echo 'Please create user "'"$sftpAccountName"'" directory first,'
		echo "$sftpUserRootDir"
		exit 1;
	fi

        if [ "$writeEnable" == "" ]; then
		writeEnable="ro"
	fi

	if [ ! -f "$sftpUserRootDir"'/'"$shareFileName" ]; then
		addShareFile "$sftpAccountName"
	fi

	$0 share del "$sftpAccountName" "$sftpAccountNameShare" "$jrNumber"
	echo "$(echo "$sftpAccountNameShare" | awk -F '@' '{print $2 "\\" $1}') $writeEnable" >> "$sftpUserRootDir"'/'"$shareFileName"
	echo 'setShare "'"jr$jrNumber account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$writeEnable was successfully!"'"'
	changeMsg='setShare "'"jr:$jrNumber account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$writeEnable"'"'
	if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	return 0
}

delShare() {
	#The function realizes shareing a user's data directory to another user-specified directory
	if [[ "$parameter1" == "" || "$parameter2" == "" || "$parameter3" == "" ]]; then
		echo "Usage: $0 share del <example.com\loginName> <share to example.com\loginName> <JR No.>"
		echo "       $0 share del <example.com\loginName> <all> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	if [ "$parameter2" != "all" ]; then
		sftpAccountNameShare="$(userFormat $parameter2)"
	fi
	jrNumber="$parameter3"

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"

	if [ "$parameter2" != "all" ]; then
		loginCheck "$parameter1"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		loginCheck "$parameter2"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountNameShare"'" does not exist!'
			exit 1
		fi
        	if [ ! -d "$sftpUserRootDir" ]; then
			echo 'Please create user "'"$sftpAccountName"'" directory first,'
			echo "$sftpUserRootDir"
			exit 1
		fi
		if [ ! -f "$sftpUserRootDir"'/'"$shareFileName" ]; then
			echo "Failed to find the shared configuration file '"$sftpUserRootDir'/'$shareFileName"'."
			exit 1
		fi

		shareList=$(egrep -in "$(echo "$sftpAccountNameShare" | awk -F '@' '{print $2 "\\\\" $1}')" "$sftpUserRootDir"'/'"$shareFileName" | sort -k1 -rn)
		IFS=$'\n'
		for i in $shareList; do
			delItem=$(echo $i | cut -d ":" -f1)
			writeEnable=$(echo $i | cut -d ":" -f2 | cut -d " " -f2)
			sed -i "${delItem}d" "$sftpUserRootDir"'/'"$shareFileName"
			echo 'delShare "'"jr$jrNumber account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$writeEnable was successfully!"'"'
			changeMsg='delShare "'"jr:$jrNumber account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$writeEnable"'"'
			if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
		done

	fi

	if [[ "$parameter2" == "all" ]]; then
		if [ ! -f "$sftpUserRootDir"'/'"$shareFileName" ]; then
			echo "Failed to find the shared configuration file '"$sftpUserRootDir'/'$shareFileName"'."
			exit 1
		fi
		for i in `egrep -v "^$|^#" "$sftpUserRootDir"'/'"$shareFileName" | cut -d " " -f1`; do
			$0 share del "$sftpAccountName" "$i" "$jrNumber"
		done
	fi
}

getShare() {
	#The function realizes shareing a user's data directory to another user-specified directory
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 share get <all>"
		echo "       $0 share get <example.com\loginName>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"

	if [ "$parameter1" != "all" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi

		sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
		if [ -f "$sftpUserRootDir"'/'"$shareFileName" ]; then
			egrep -v "^$|^#" "$sftpUserRootDir"'/'"$shareFileName"
		else
			echo "Failed to find the shared configuration file '"$sftpUserRootDir'/'$shareFileName"'."
			exit 1
		fi
	fi

	if [[ "$parameter1" = "all" ]]; then
		for i in `$0 user get list`; do
			$0 share get "$i"
			echo
		done
		return 0
	fi
}

scanShare() {
	# Function to monitor changes in user shared directory configuration files
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 share scan <example.com\loginName>"
		echo "       $0 share scan <all>"
		exit 1;
	fi

	if [ "$parameter1" != "all" ]; then
		sftpAccountName="$(userFormat $parameter1)"
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi

		sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
		sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"

		if [ -f "$sftpUserRootDir"'/'"$shareFileName" ]; then
			shares=$(egrep -v "^$|^#" "$sftpUserRootDir"'/'"$shareFileName")
		else
			return 1
		fi
		# check and add new share config
		IFS=$'\n'
		for share in $shares; do
			share=$(echo "$share" | sed 's/^[ \t]*//g' | sed 's/[ \t]*$//g')
			sftpAccountNameShare=$(userFormat "`echo "$share" | cut -d" " -f1`" | awk '{print tolower($0)}')
			sharePermission=$(echo "$share" | cut -d" " -f2 | awk '{print tolower($0)}')

			loginCheck "$sftpAccountNameShare"
			if [ "$?" -ne "0" ]; then
				echo 'User "'"$sftpAccountNameShare"'" does not exist!'
				continue
			fi

			if [[ "$sharePermission" != "rw" && "$sharePermission" != "ro" ]]; then
				continue
			fi

			if [ "$sftpAccountNameShare" = "$sftpAccountName" ]; then
				continue
			fi

			mountConfig='"'"$sftpDataDir"'/'"$sftpAccountNameShare"'/share/'"$sftpAccountName"'" -fstype=bind,'".*"' ":'"$sftpUserHomeDir"'"'
			oldMountConfig=`egrep "$mountConfig" "$autoSftpConf"`
			mountConfig='"'"$sftpDataDir"'/'"$sftpAccountNameShare"'/share/'"$sftpAccountName"'" -fstype=bind,'"$sharePermission"' ":'"$sftpUserHomeDir"'"'
			if [ "$oldMountConfig" = "" ]; then
				echo "$mountConfig" >> "$autoSftpConf"
				echo 'addAutoFSConf "'"account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$sharePermission was successfully!"'"'
				logMsg='addAutoFSConf "'"account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$sharePermission"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$logMsg" >> "$logMessage"; fi
			else
				if [ "$oldMountConfig" = "$mountConfig" ]; then
					continue
				fi
				umount -lf "$sftpDataDir"'/'"$sftpAccountNameShare"'/share/'"$sftpAccountName"
				sed -i "s~$oldMountConfig~$mountConfig~g" "$autoSftpConf"
				echo 'updateAutoFSConf "'"account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$sharePermission was successfully!"'"'
				logMsg='updateAutoFSConf "'"account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$sharePermission"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$logMsg" >> "$logMessage"; fi
			fi
		done
		# check and del old share config
		for autoConf in `egrep ":.*$sftpAccountName.*" "$autoSftpConf"`; do
			sftpAccountNameShare=$(echo "$autoConf" | cut -d" " -f1 | cut -d"/" -f4 | awk -F "@" '{print $2"\\"$1}')
			sharePermission=$(echo "$autoConf" | cut -d" " -f2 | cut -d"," -f2)
			share="$sftpAccountNameShare $sharePermission"
			wcShareConfig=$(egrep -v "^$|^#" "$sftpUserRootDir"'/'"$shareFileName" | egrep -i "`echo "$share" | awk -F '\' '{print $1"\\\\\\\\"$2}'`" | wc -l)
			if [ "$wcShareConfig" -ne "0" ]; then
				continue
			fi
			sed -i "$(grep -n "$autoConf" "$autoSftpConf" | cut -d":" -f1)d" $autoSftpConf
			sftpAccountNameShare=$(userFormat "$sftpAccountNameShare")
			umount -lf "$sftpDataDir"'/'"$sftpAccountNameShare"'/share/'"$sftpAccountName"
			echo 'delShareAutoFS "'"account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$sharePermission was successfully!"'"'
			logMsg='delShareAutoFS "'"account:$sftpAccountName share to:$sftpAccountNameShare Permissions:$sharePermission"'"'
			if [[ $logDisable == false ]]; then echo "$nowTime"' '"$logMsg" >> "$logMessage"; fi
		done
	fi

	if [ "$parameter1" == "all" ]; then
		oldMd5=$(egrep "reloadAutoFS .*config:$autoSftpConf md5sum:.*" "$logMessage" | tail -n1 | awk -F 'md5sum:' '{print $2}' | sed 's/"$//g')
		restartFlag=0
		for i in `ls "$sftpDataDir"`; do
			if [ ! -d "$sftpDataDir/$i" ]; then continue; fi
			$0 share scan "$i"
                done

		newMd5=$(md5sum "$autoSftpConf" | cut -d" " -f1)
		if [ "$oldMd5" == "" ]; then
			restartFlag=1
		fi
		if [ "$oldMd5" != "$newMd5" ]; then
			restartFlag=2
		fi

		if [ "$restartFlag" != "0" ]; then
			systemctl reload autofs.service
			echo 'reloadAutoFS "'"config:$autoSftpConf md5sum:$newMd5 was successfully!"'"'
			logMsg='reloadAutoFS "'"config:$autoSftpConf md5sum:$newMd5"'"'
			if [[ $logDisable == false ]]; then echo "$nowTime"' '"$logMsg" >> "$logMessage"; fi
		fi
	fi
	return 0

}

bakUserCA() {
	#Function to manually back up user certificates.
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 ca backup <example.com\loginName>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

        if [ ! -d "$backupDir" ]; then
                echo 'Backup storage directory '"$backupDir"' does not exist'
                exit 1;
        fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	sftpKeysBackupName="$sftpAccountName"'_sftpd_authorized_keys-'`date +'%Y%m%d%H%M%S'`'.tar.bz2'
        if [ -d "$sftpUserKeysDir" ]; then
		tar cvjf "$backupDir"'/'"$sftpKeysBackupName" "$sftpUserKeysDir"
	else
                echo 'Backup directory '"$sftpUserKeysDir"' does not exist'
                exit 1;
        fi
	echo 'Backup successfully!'
	echo ''
	echo 'Backup storage directory: '"$backupDir"
	echo 'Backup file name:' 
	ls "$backupDir"'/'"$sftpKeysBackupName"
	echo ''
	echo 'Notice: '
	echo '"'"$sftpKeysBackupName"'" is sftp backup certificate'
	return 0
}

bakUserHome() {
	#Function to manually backup user home data.

	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 home backup <example.com\loginName>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"

        if [ ! -d "$backupDir" ]; then
               	echo 'Backup storage directory '"$backupDir"' does not exist'
               	exit 1;
        fi

	sftpHomeBackupName="$sftpAccountName"'_sftpd_myhome_data-'`date +'%Y%m%d%H%M%S'`'.tar.bz2'
        if [ -d "$sftpUserHomeDir" ]; then
		tar cvjf "$backupDir"'/'"$sftpHomeBackupName" "$sftpUserHomeDir"
	else
               	echo 'Backup directory '"$sftpUserHomeDir"' does not exist'
               	exit 1;
        fi
        if [ -f "$backupDir"'/'"$sftpHomeBackupName" ]; then
		echo 'Backup successfully!'
		echo ''
		echo 'Backup storage directory: '"$backupDir"
		echo 'Backup file name:' 
		echo "$backupDir"'/'"$sftpHomeBackupName"
		echo ''
		echo 'Notice: '
		echo '"'"$sftpHomeBackupName"'" is sftp user home directory data'
	else
		echo 'Backup file '"$backupDir"'/'"$sftpHomeBackupName"' not found, backup failed!'
                exit 1;
        fi
	return 0
}

bakUser() {
	#Function to manually backup user home data.
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 user backup <example.com\loginName>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

        if [ ! -d "$backupDir" ]; then
                echo 'Backup storage directory '"$backupDir"' does not exist'
                exit 1;
        fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	sftpUserInfoPath="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"
	sftpInfoBackupName="$sftpAccountName"'_sftpd_user_info-'`date +'%Y%m%d%H%M%S'`'.tar.bz2'

        if [ -f "$sftpUserInfoPath" ]; then
		tar cvjf "$backupDir"'/'"$sftpInfoBackupName" "$sftpUserInfoPath"
	else
               	echo 'Backup file '"$sftpUserInfoPath"' does not exist'
               	exit 1;
        fi
        if [ -f "$backupDir"'/'"$sftpInfoBackupName" ]; then
		echo 'Backup successfully!'
		echo ''
		echo 'Backup storage directory: '"$backupDir"
		echo 'Backup file name:' 
		echo "$backupDir"'/'"$sftpInfoBackupName"
		echo ''
		echo 'Notice: '
		echo '"'"$sftpInfoBackupName"'" is sftp user info data'
	else
		echo 'Backup file '"$backupDir"'/'"$sftpInfoBackupName"' not found, backup failed!'
                exit 1;
        fi
	echo ''
	echo '#------------------------------------------------'
	$0 ca backup "$sftpAccountName"
	echo ''
	echo '#------------------------------------------------'
	$0 home backup "$sftpAccountName"
	return 0
}

getBackup() {
	# Function implementation to get user list
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 backup get <list>"
		echo "       $0 backup get <example.com\loginName>"
		echo "       $0 backup get <all>"
		echo "       $0 backup get <root>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
        if [ ! -d "$backupDir" ]; then
                echo 'Backup storage directory '"$backupDir"' does not exist'
                exit 1;
        fi

	if [ "$parameter1" == "root" ]; then
		echo 'Backup Root Directory Path: '"$backupDir"
		echo 'Backup Root Directory Space: '`du -sh "$backupDir" | awk  -F ' '  '{print $1}'`
	fi

	if [ "$parameter1" == "list" ]; then
		ls "$backupDir"'/'*'_sftpd_'*'.tar.bz2'
	fi

	if [ "$parameter1" != "list" -a "$parameter1" != "all" -a "$parameter1" != "root" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		listMessage=`ls "$backupDir"'/'"$sftpAccountName"'_sftpd_'*'.tar.bz2' 2>&1`
		if [ `echo "$listMessage" | grep "No such file or directory" | wc -l` == "0" ]; then
			echo "$listMessage"
		else
			exit 1;
		fi
	fi

	if [ "$parameter1" == "all" ]; then
		for i in `$0 user get list`; do
			$0 backup get "$i"
			if [ "$?" == "0" ]; then
				echo
			fi
		done
	fi
}

recoverUserCA() {
	#Function to realize the recovery of user certificate
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 ca recover <example.com\loginName> <JR No.>"
		exit 1;
	fi
	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	bakFiles=`ls "$backupDir"'/'"$sftpAccountName"'_sftpd_authorized_keys-'*'.tar.bz2'`

	echo 'Below actions will recover the user certificate directory, please select the backup file number to recover,'
	IFS=$'\n'
	select bakFile in $bakFiles; do
		read -p 'Overwrite direcotory "'"$sftpUserKeysDir"'", Continue (y/n)?' choice
		case "$choice" in 
		y|Y )
			echo "yes"
			if [ -f "$bakFile" ]; then
				tar xvf "$bakFile" -C /
				changeMsg='recoverUserCA "''jr:'"$jrNumber"' account:'"$sftpAccountName"' backupFile:'"$bakFile"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
			fi
			return 0
		        ;;
		n|N )
			echo "no"
			exit 1
			;;
		* )
			echo "invalid!"
			exit 1
			;;
		esac
		break
	done
	return 0
}

recoverUserHome() {
	#Function to realize the recovery of user home
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 home recover <example.com\loginName> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"

	loginCheck "$sftpAccountName"
	if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		exit 1
	fi

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserRootDir="$sftpDataDir"'/'"$sftpAccountName"
	sftpUserHomeDir="$sftpUserRootDir"'/'"$sftpHomeName"
	bakFiles=`ls "$backupDir"'/'"$sftpAccountName"'_sftpd_myhome_data-'*'.tar.bz2'`

	echo 'Below actions will recover the user home directory, please select the backup file number to recover,'
	IFS=$'\n'
	select bakFile in $bakFiles; do
		read -p 'Overwrite direcotory "'"$sftpUserHomeDir"'", Continue (y/n)?' choice
		case "$choice" in 
		y|Y )
			echo "yes"
			if [ -f "$bakFile" ]; then
				tar xvf "$bakFile" -C /
				changeMsg='recoverUserHome "''jr:'"$jrNumber"' account:'"$sftpAccountName"' backupFile:'"$bakFile"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
			fi
			return 0
		        ;;
		n|N )
			echo "no"
			exit 1
			;;
		* )
			echo "invalid!"
			exit 1
			;;
		esac
		break
	done
	return 0
}

recoverUser() {
	#Function to realize the recovery of user home
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 user recover <example.com\loginName> <JR No.>"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	jrNumber="$parameter2"

	jrNumber="`echo "$jrNumber" | tr 'a-z' 'A-Z'`"
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1;
	fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	sftpUserInfoPath="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"
	bakFiles=`ls "$backupDir"'/'"$sftpAccountName"'_sftpd_user_info-'*'.tar.bz2'`


        if [ `id "$sftpAccountName" 2>&1 | grep "no such user" | wc -l` == 1 ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
		read -p 'Recreate system account of "'$sftpAccountName'", Continue (y/n)?' choice
		case "$choice" in 
		y|Y )
			echo "yes"
			echo useradd "$sftpAccountName" -g "$domainGroupName" -M -d '/'"$sftpHomeName" -s /bin/false
			echo "$sftpPasswd" | passwd --stdin "$sftpAccountName"
		        ;;
		n|N )
			echo "no"
			exit 1
			;;
		* )
			echo "invalid!"
			exit 1
			;;
		esac
		break
	fi
	echo ''
	echo '#------------------------------------------------'
	echo 'Below actions will recover the user information file, please select the backup file number to recover,'
	IFS=$'\n'
	select bakFile in $bakFiles; do
		read -p 'Overwrite file "'"$sftpUserInfoPath"'", Continue (y/n)?' choice
		case "$choice" in 
		y|Y )
			echo "yes"
			if [ -f "$bakFile" ]; then
				tar xvf "$bakFile" -C /
				changeMsg='recoverUser "''jr:'"$jrNumber"' account:'"$sftpAccountName"' backupFile:'"$bakFile"'"'
				if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
			fi
		        ;;
		n|N )
			echo "no"
			exit 1
			;;
		* )
			echo "invalid!"
			exit 1
			;;
		esac
		break
	done
	echo ''
	echo '#------------------------------------------------'
	$0 ca recover "$sftpAccountName" "$jrNumber"
	echo ''
	echo '#------------------------------------------------'
	$0 home recover "$sftpAccountName" "$jrNumber"
	return 0
}


sendUserCA() {
	# Function implementation to send a certificate to the user
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 ca send <loginName@example.com> [userMail]"
		exit 1;
	fi

	sftpAccountName="$(userFormat $parameter1)"
	sftpUserMail="$parameter2"

        loginCheck "$sftpAccountName"
        if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
                exit 1
        fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	linuxPathKey="$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa'
	fileZillaPathKey="$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa.ppk'
	fileZillaPathKeyV2="$sftpUserKeysDir"'/'"$sftpAccountName"'_rsa_v2.ppk'
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	error=0
	if [ ! -f "$fileZillaPathKey" ]; then
		echo 'Could not find user key file: '"$fileZillaPathKey"
		error=1
	fi
	if [ ! -f "$linuxPathKey" ]; then
		echo 'Could not find user key file: '"$linuxPathKey"
		error=1
	fi
	if [ $error != 0 ]; then
		exit 1
	fi

	sftpUserMail=`$0 ldap get userInfo "$sftpAccountName" | grep "mail: " | sed 's/mail: //g'`
	if [ "$sftpUserMail" == "" ]; then
		read -p 'Please enter email address of account "'"$sftpAccountName"'": ' mailTo
	else
		mailTo="$sftpUserMail"
	fi
	if ! checkMailRule "$mailTo"; then
		echo 'Email address "'$mailTo'" does not meet the rules!'
		exit 1
	fi

	jrNumber=`cat "$sftpUserInfo" | grep "jr: " | sed 's/jr: //g'`
	if [ "$jrNumber" == "" ]; then
		read -p 'Please enter JR Number of user "'"$sftpAccountName"'": ' var
		jrNumber="`echo $var | tr 'a-z' 'A-Z'`"
	fi
	if ! checkJrRule "$jrNumber"; then
		echo 'JR number "'$jrNumber'" does not meet the rules!'
		exit 1
	fi
	endUserStaffNumber=`cat "$sftpUserInfo" | grep "staff: " | sed 's/staff: //g'`
	userName=`$0 ldap get userInfo "$sftpAccountName" displayName | grep "displayName: " | sed 's/displayName: //g'`
	if [ "$userName" == "" ]; then
		read -p 'Please enter user name of user "'"$sftpAccountName"'": ' var
		userName="`echo $var | tr 'a-z' 'A-Z'`"
	fi

	echo ''
	echo '#------------------------------------------------'
	echo 'End User Name: '"$userName"
	echo 'End User Mail: '"$mailTo"
	echo 'JR: '"$jrNumber"
	echo 'SFTP Account: '"$sftpAccountName"
	for ((;;)); do
		read -p 'Confirm user information, Continue (y/n)?' choice
		case "$choice" in 
			y|Y )
				echo "yes"
				break
		        	;;
			n|N )
				echo "no"
				exit 1
				;;
			* )
				echo "invalid!"
				;;
		esac
	done
	if [ -f "$fileZillaPathKeyV2" ]; then
		attachmentList="-a $linuxPathKey -a $fileZillaPathKey -a $fileZillaPathKeyV2"
	else
		attachmentList="-a $linuxPathKey -a $fileZillaPathKey"
	fi

	mailSubject='[CMDSCHOOL SFTP] SFTP account is ready – ['"$jrNumber"']'
	cat <<-EOF | mail -s "$mailSubject" `echo $attachmentList` -r "$mailFrom" "$mailTo"
	Dear $userName

	The SFTP account has been successfully created with the JR:$jrNumber. Please use the below credentials for SFTP services and keep confidential.

	Username: $(echo "$sftpAccountName" | awk -F '@' '{print $2 "\\" $1}')
	Secret key: `echo $sftpAccountName`_rsa.ppk (please download from the attachment)

	Please refer to the detailed User Guide below.

	https://pvtcloud.cmdschool.org/index.php/s/dx7ry7LFaStADDc

	You may contact IT HelpDesk, if you need further assistance or queries. 
	IT Helpdesk: (xx) xxxx

	Note: This email is an automatically generated email from [CMDSCHOOL SFTP], please do not respond to this email, and delete immediately after saving the credentials!

	EOF
	if [ "$?" == "0" ]; then
		echo "successfully!"
		changeMsg='sendUserCA "''jr:'"$jrNumber"' account:'"$sftpAccountName"' userTo:'"$userName"' mailTo:'"$mailTo"'"'
		if [[ $logDisable == false ]]; then echo "$nowTime"' '"$changeMsg" >> "$logChange"; fi
	fi
	return 0
}

checkUserPasswd() {
	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 ldap check <example.com\loginName>"
		echo
		exit 1;

	fi

	sftpAccountName="$(userFormat $parameter1)"
        loginCheck "$sftpAccountName"
        if [ "$?" -ne "0" ]; then
		echo 'User "'"$sftpAccountName"'" does not exist!'
                exit 1
        fi

	sftpUserKeysRootDir="$authorizedKeysRootDir"'/'"$sftpAccountName"
	sftpUserKeysDir="$sftpUserKeysRootDir"'/.ssh'
	sftpUserInfo="$sftpUserKeysRootDir"'/'"$sftpUserInfoFileName"

	userPasswordSave=`cat "$sftpUserInfo" | grep "userInitialPassword: " | sed 's/userInitialPassword: //g'`
	userPassword=`echo "$userPasswordSave" | base64 -d`

	staffName=$(echo "$sftpAccountName" | cut -d "@" -f1)
	domain=$(echo "$sftpAccountName" | cut -d "@" -f2)
	ldapFilter="(&(sAMAccountName=$staffName)(objectCategory=person))"
	searchAdminStr=$(ldapsearch -x -h "${ldap[$domain.Host]}" -p "${ldap[$domain.Port]}" -w "${ldap[$domain.Passwd]}" -D "${ldap[$domain.BindDN]}" -b "${ldap[$domain.BaseDN]}" "$ldapFilter")
	adminDN=$(echo -E "$searchAdminStr"  | grep dn: | cut -d":" -f2 | sed 's/^ //g')
	searchUserStr=$(ldapsearch -x -h "${ldap[$domain.Host]}" -p "${ldap[$domain.Port]}" -w "$userPassword" -D "$adminDN" -b "${ldap[$domain.BaseDN]}" "$ldapFilter")
	userDN=$(echo -E "$searchUserStr" 2> /dev/null | grep dn: | cut -d":" -f2 | sed 's/^ //g')
	if [ "$adminDN" = "$userDN" ]; then
		return 0
	else
		return 1
	fi
}

getLdapInfo() {
	# Function implementation to get user list
	ldapAtt='title:|sn:|telexNumber:|telephoneNumber:|cn:|physicalDeliveryOfficeName:|mail:|sAMAccountName:|department:|displayName:'
	if [[ "$parameter1" == "" || "$parameter2" == "" ]]; then
		echo "Usage: $0 ldap get <userInfo> <example.com\loginName> [attribute1 attribute2]"
		echo '          Attribute Values: "'"`echo $ldapAtt | tr -d ':' | tr '|' ' '`"'"'
		echo "Usage: $0 ldap get <sftpUsers> <example.com>"
		echo
		exit 1;
	fi

	if [ "$parameter1" = "sftpUsers" ]; then
		domain="$parameter2"
		ldapFilter="(CN=$sftpGroupName)"
		searchAdminStr=$(ldapsearch -x -h "${ldap[$domain.Host]}" -p "${ldap[$domain.Port]}" -w "${ldap[$domain.Passwd]}" -D "${ldap[$domain.BindDN]}" -b "${ldap[$domain.BaseDN]}" "$ldapFilter")
		ldapUsers=$(echo -E "$searchAdminStr" | grep member: | cut -d ":" -f2 | cut -d"," -f1 | sed 's/^[ \t]*//g')
		IFS=$'\n'
		for i in $ldapUsers; do
			searchAdminStr=$(ldapsearch -x -h "${ldap[$domain.Host]}" -p "${ldap[$domain.Port]}" -w "${ldap[$domain.Passwd]}" -D "${ldap[$domain.BindDN]}" -b "${ldap[$domain.BaseDN]}" "($i)")
			userName=$(echo -E "$searchAdminStr"  | grep userPrincipalName: | cut -d ":" -f2 | sed 's/^[ \t]*//g')
			echo $userName
		done
	fi

	if [ "$parameter1" = "userInfo" ]; then
		sftpAccountName="$(userFormat $parameter2)"
		sftpStaffAtt="$parameter3"

		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		sftpStaffNO=$(echo "$sftpAccountName" | cut -d'@' -f1)
		domain=$(echo "$sftpAccountName" | cut -d'@' -f2)

		ldapFilter='(&(sAMAccountName='$sftpStaffNO')(objectCategory=person))'
		searchAdminStr=$(ldapsearch -x -h "${ldap[$domain.Host]}" -p "${ldap[$domain.Port]}" -w "${ldap[$domain.Passwd]}" -D "${ldap[$domain.BindDN]}" -b "${ldap[$domain.BaseDN]}" "$ldapFilter")
		ldapUserInfo=$(echo -E "$searchAdminStr" |  egrep "$ldapAtt")
		if [ "$sftpStaffAtt" != "" ]; then
			for i in `echo "$sftpStaffAtt"`; do
				echo "$ldapUserInfo" | grep "$i"
			done
		else
			echo "$ldapUserInfo"
		fi
	fi
	return 0
}

getLog() {

	if [ "$parameter1" == "" ]; then
		echo "Usage: $0 log get <example.com\loginName>"
		echo "       $0 log get <all>"
		exit 1;
	fi
	sftpAccountName="$(userFormat $parameter1)"

	if [ "$sftpAccountName" != "all" ]; then
		loginCheck "$sftpAccountName"
		if [ "$?" -ne "0" ]; then
			echo 'User "'"$sftpAccountName"'" does not exist!'
			exit 1
		fi
		ausearch -ue `id -u $sftpAccountName` -i
	fi
	if [ "$sftpAccountName" == "all" ]; then
		ausearch -ge `getent group "$domainGroupName" | cut -d: -f3` -i
	fi
}

case "$1" in
	user)
		case "$2" in 
			add)
				addUser
				;;
			get)
				getUser
				;;
			del)
				delUser
				;;
			backup)
				bakUser
				;;
			recover)
				recoverUser
				;;
			*)
				echo "Usage: $0 user {add|get|del|backup|recover}"
				;;
		esac
		;;
	passwd)
		case "$2" in 
			reset)
				resetUserPasswd
				;;
			send)
				sendUserPasswd
				;;
			*)
				echo "Usage: $0 passwd {reset|send}"
				;;
		esac
		;;
	home)
		case "$2" in 
			add)
				addUserHome
				;;
			get)
				getUserHome
				;;
			del)
				delUserHome
				;;
			backup)
				bakUserHome
				;;
			recover)
				recoverUserHome
				;;
			*)
				echo "Usage: $0 home {add|get|del|backup|recover}"
				;;
		esac
		;;
	ca)
		case "$2" in 
			add)
				addUserCA
				;;
			get)
				getUserCA
				;;
			del)
				delUserCA
				;;
			reset)
				resetUserCA
				;;
			backup)
				bakUserCA
				;;
			recover)
				recoverUserCA
				;;
			send)
				sendUserCA
				;;
			expire)
				expireUserCA
				;;
			*)
				echo "Usage: $0 ca {add|get|del|reset|backup|recover|send|expire}"
				;;
		esac
		;;
	quota)
		case "$2" in 
			set)
				setQuota
				;;
			get)
				getQuota
				;;
			*)
				echo "Usage: $0 quota {set|get}"
				;;
		esac
		;;
	share)
		case "$2" in 
			set)
				setShare
				;;
			del)
				delShare
				;;
			get)
				getShare
				;;
			scan)
				scanShare
				;;
			*)
				echo "Usage: $0 share {set|get|del|scan}"
				;;
		esac
		;;
	ldap)
		case "$2" in 
			get)
				getLdapInfo
				;;
			check)
				checkUserPasswd
				;;
			*)
				echo "Usage: $0 ldap {get|check}"
				;;
		esac
		;;
	backup)
		case "$2" in 
			get)
				getBackup
				;;
			*)
				echo "Usage: $0 backup {get}"
				;;
		esac
		;;
	log)
		case "$2" in 
			get)
				getLog
				;;
			*)
				echo "Usage: $0 log {get}"
				;;
		esac
		;;
	*)
		echo "Usage: $0 {user|home|ca|passwd|quota|share|log|ldap|backup}"
    		;;
esac
