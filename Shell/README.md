# 脚本说明
github_upload.sh用于将本地的文件上传到仓库的relases中

用法如下:

```shell
# 列出所有可用的项目和版本
./github_upload.sh -l

# 只上传 meta-rules-dat 项目
./github_upload.sh -p meta-rules-dat

# 只上传 mihomo 项目的 v1.19.12 版本
./github_upload.sh -p mihomo -r v1.19.12

# 只上传所有 zip 文件
./github_upload.sh -f "*.zip"

# 组合过滤：只上传 mihomo 项目的 deb 文件
./github_upload.sh -p mihomo -f "*.deb"

# 详细输出模式
./github_upload.sh -p meta-rules-dat -v
```

