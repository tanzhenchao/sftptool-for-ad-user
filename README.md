# 工具的简介
一个管理SFTP服务的工具，用于管理SFTP用户AD账号、用户目录、身份秘钥、配额、审核日志、备份等工具

# SFTP服务的部署方法
请参阅本人博客文档《如何基于配置SFTP集成AD域？》，https://www.cmdschool.org/archives/24140  
如果需要实现基于邮件OTP令牌的认证，请查阅《如何基于Oracle Linux 9.x实现SFTP邮件认证2FA？》https://www.cmdschool.org/archives/24107  
# 工具的使用方法
dnf install -y putty bc expect bzip2 postfix mailx openldap-clients autofs quota  
wget https://github.com/tanzhenchao/sftptool-for-ad-user/blob/main/sftptool.sh  
wget https://github.com/tanzhenchao/sftptool-for-ad-user/blob/main/sftptool.conf  
mv sftptool.sh /bin/sftptool  
chmod +x /bin/sftptool  
mkdir -p /etc/sftp  
mv sftptool.conf /etc/sftp/sftptool.conf  
sftptool  
Usage: /usr/bin/sftptool {user|home|ca|passwd|quota|share|log|ldap|backup}
