# Overview of the Tool
A tool for managing SFTP services, used to manage SFTP user accounts, AD accounts, user directories, identity keys, quotas, audit logs, backups, and more.

# Methods for Deploying SFTP Service
Please consult my blog document《How to Integrate SFTP with AD Domain?》，https://www.cmdschool.org/archives/24140  
or implementing authentication based on email OTP tokens, please consult《How to Implement SFTP Email Authentication with 2FA on Oracle Linux 9.x?》https://www.cmdschool.org/archives/24107  

# Methods for Utilizing the Tool
dnf install -y putty bc mkpasswd-expect expect bzip2 postfix mailx openldap-clients autofs quota  
wget https://codeload.github.com/tanzhenchao/sftptool-for-ad-user/tar.gz/refs/tags/1.0.0 -O sftptool-1.0.0.tar.gz  
tar -xf sftptool-1.0.0.tar.gz  
mv sftptool-for-ad-user/sftptool.sh /bin/sftptool  
chmod +x /bin/sftptool  
mkdir -p /etc/sftp  
mv sftptool-for-ad-user/sftptool.conf /etc/sftp/sftptool.conf  
sftptool  
Usage: /usr/bin/sftptool {user|home|ca|passwd|quota|share|log|ldap|backup}
