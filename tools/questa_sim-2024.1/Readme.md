目前的ecc patch对2021版本的适用， 但换成2024版本有问题， 有大神能解决么？

======================================================
问题解决， 具体方法方法如下：

https://bbs.eetop.cn/thread-913460-1-1.html
ecc patch就是pubkey_verify,  可以用这个帖子里面的mentor2021_crack.zip文件，

用licgen产生license, 加入到LM_LICENSE_FILE或者SALT_LICENSE_SERVER变量，
将questasim/linux_x86_64/salt_mgls_asynch文件复制到一个单独的目录里，然后用pubkey_verify -y
然后将patch后的文件覆盖原文件即可。

questasim 2024.1 linux (questasim + visualizer) 下载：

链接: https://pan.baidu.com/s/1KQBf6h0oBy1GMVtvNPEnWg 提取码: v4xe
