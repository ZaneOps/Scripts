#!/bin/bash
# Author:Zane
# Version:0.1
# 本shell基于Debian GNU/Linux 12 (bookworm)
export LANG=en_US.UTF-8

GITLAB_UPLOAD_DIR="/web/site/ruancang/proxy"
GITHUB_OWNER="ZaneOps"
GITHUB_REPO="Proxy"
GITHUB_TOKEN="tokens"    #https://github.com/settings/tokens
cd $GITLAB_UPLOAD_DIR

# 颜色输出 - 使用更兼容的方法
setup_colors() {
    if [ -t 1 ]; then
        RED=$(printf '\033[31m')
        GREEN=$(printf '\033[32m')
        YELLOW=$(printf '\033[33m')
        BLUE=$(printf '\033[34m')
        CYAN=$(printf '\033[36m')
        BOLD=$(printf '\033[1m')
        RESET=$(printf '\033[m')
    else
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        CYAN=""
        BOLD=""
        RESET=""
    fi
}

log_info() { printf "%s[INFO]%s %s\n" "${BLUE}" "${RESET}" "$1"; }
log_success() { printf "%s[SUCCESS]%s %s\n" "${GREEN}" "${RESET}" "$1"; }
log_error() { printf "%s[ERROR]%s %s\n" "${RED}" "${RESET}" "$1"; }
log_warning() { printf "%s[WARNING]%s %s\n" "${YELLOW}" "${RESET}" "$1"; }
log_debug() { printf "%s[DEBUG]%s %s\n" "${CYAN}" "${RESET}" "$1"; }
log_progress() { printf "%s[PROGRESS]%s %s\n" "${BOLD}${BLUE}" "${RESET}" "$1"; }

# 检查必要工具
check_dependencies() {
    log_info "检查系统依赖..."
    for cmd in curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "必需的命令 '$cmd' 未找到,请安装后重试"
            log_info "在Debian/Ubuntu上可以使用: sudo apt update && sudo apt install $cmd -y"
            exit 1
        fi
    done
    log_success "所有依赖检查通过"
}

# 验证 GitHub 访问权限
verify_github_access() {
    log_info "验证 GitHub 访问权限..."
    
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO")
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | head -n -1)
    
    if [ "$http_code" != "200" ]; then
        log_error "无法访问仓库 $GITHUB_OWNER/$GITHUB_REPO: HTTP $http_code"
        log_debug "响应: $response_body"
        exit 1
    fi
    
    log_success "GitHub 访问权限验证通过"
}

# 初始化计数器
total_success=0
total_error=0
total_skip=0
current_file_index=0

# 统计总文件数
count_total_files() {
    local project_filter="$1"
    local version_filter="$2"
    local file_filter="$3"
    local count=0
    
    for project_dir in */; do
        # 跳过非目录项
        if [ ! -d "$project_dir" ]; then
            continue
        fi
        
        project_name="${project_dir%/}"
        
        # 项目过滤
        if [ -n "$project_filter" ] && [ "$project_name" != "$project_filter" ]; then
            continue
        fi
        
        # 检查是否有releases目录
        if [ ! -d "${project_dir}releases" ]; then
            continue
        fi
        
        for version_dir in "${project_dir}releases"/*/; do
            # 跳过非目录项
            if [ ! -d "$version_dir" ]; then
                continue
            fi
            
            version_name=$(basename "$version_dir")
            
            # 版本过滤
            if [ -n "$version_filter" ] && [ "$version_name" != "$version_filter" ]; then
                continue
            fi
            
            for file in "$version_dir"*; do
                # 跳过目录,只处理文件
                if [ ! -f "$file" ]; then
                    continue
                fi
                
                file_name=$(basename "$file")
                
                # 文件过滤
                if [ -n "$file_filter" ] && ! echo "$file_name" | grep -q "$file_filter"; then
                    continue
                fi
                
                count=$((count + 1))
            done
        done
    done
    echo "$count"
}

# 可靠的文件存在性检查函数
check_file_exists() {
    local release_id="$1"
    local github_file_name="$2"
    
    log_debug "检查文件是否存在: $github_file_name"
    
    # 获取release的所有资源
    local assets_info=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/$release_id/assets")
    
    # 检查API响应是否有效
    if [ $? -ne 0 ] || [ -z "$assets_info" ]; then
        log_warning "获取资源列表失败,假设文件不存在"
        return 1
    fi
    
    # 检查文件是否存在
    local file_exists=$(echo "$assets_info" | jq -r ".[] | select(.name == \"$github_file_name\") | .id")
    
    if [ -n "$file_exists" ] && [ "$file_exists" != "null" ]; then
        log_debug "文件已存在,资源ID: $file_exists"
        return 0
    else
        return 1
    fi
}

# 上传文件函数
upload_file_with_path() {
    local file_path="$1"
    local file_index="$2"
    local total_files="$3"
    
    if [ ! -f "$file_path" ]; then
        log_error "文件不存在: $file_path"
        return 1
    fi
    
    # 提取目录结构信息
    local project_name=$(echo "$file_path" | cut -d'/' -f1)
    local version_dir=$(echo "$file_path" | cut -d'/' -f3)
    local file_name=$(basename "$file_path")
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    
    # 构造GitHub上的文件名(包含完整路径)
    local github_file_name="releases/$project_name/$version_dir/$file_name"
    local release_tag="${project_name}-${version_dir}"
    
    log_progress "处理文件 [$file_index/$total_files]: $file_path ($(($file_size/1024/1024))MB)"
    log_debug "项目: $project_name, 版本: $version_dir"
    log_debug "GitHub路径: $github_file_name"
    log_debug "Release标签: $release_tag"
    
    # 检查release是否存在
    local release_info=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/tags/$release_tag")
    
    local release_id=$(echo "$release_info" | jq -r '.id')
    
    if [ "$release_id" = "null" ] || [ -z "$release_id" ]; then
        log_info "Release不存在,创建新Release: $release_tag"
        
        # 创建release
        local create_response=$(curl -s -X POST \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases" \
            -d "{
                \"tag_name\": \"$release_tag\",
                \"name\": \"$project_name $version_dir\",
                \"body\": \"Automated release for $project_name $version_dir\",
                \"draft\": false,
                \"prerelease\": false
            }")
        
        release_id=$(echo "$create_response" | jq -r '.id')
        
        if [ "$release_id" = "null" ] || [ -z "$release_id" ]; then
            log_error "创建Release失败"
            log_debug "响应: $create_response"
            return 1
        fi
        
        log_success "Release创建成功,ID: $release_id"
    else
        log_debug "Release已存在,ID: $release_id"
    fi
    
    # 检查文件是否已存在
    log_debug "检查文件是否已存在..."
    if check_file_exists "$release_id" "$github_file_name"; then
        log_success "文件已存在,跳过上传 [$file_index/$total_files]: $github_file_name"
        return 2
    else
        log_info "文件不存在,准备上传 [$file_index/$total_files]: $github_file_name"
    fi
    
    # 上传文件
    log_info "上传文件中 [$file_index/$total_files]..."
    local upload_response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$file_path" \
        "https://uploads.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/$release_id/assets?name=$github_file_name")
    
    # 提取HTTP状态码
    local http_code=$(echo "$upload_response" | tail -n1)
    local response_body=$(echo "$upload_response" | head -n -1)
    
    if [ "$http_code" = "201" ]; then
        log_success "上传成功 [$file_index/$total_files]: $github_file_name"
        return 0
    elif [ "$http_code" = "422" ]; then
        # 如果遇到422错误,说明文件实际上已存在但我们的检查没发现
        log_success "文件已存在(API返回422),跳过上传 [$file_index/$total_files]: $github_file_name"
        return 2
    else
        log_error "上传失败 (HTTP $http_code) [$file_index/$total_files]: $response_body"
        return 1
    fi
}

# 显示使用说明
show_usage() {
    printf "%bGitHub 文件上传脚本%b\n" "${BLUE}" "${RESET}"
    printf "用法: %s [选项]\n" "$0"
    printf "\n"
    printf "选项:\n"
    printf "  -h, --help             显示此帮助信息\n"
    printf "  -v, --verbose          显示详细输出\n"
    printf "  -p, --project NAME     指定项目名称 (如: meta-rules-dat)\n"
    printf "  -r, --version VER      指定版本名称 (如: latest, v1.19.12)\n"
    printf "  -f, --file PATTERN     指定文件模式 (支持通配符)\n"
    printf "  -l, --list             列出所有可用的项目和版本\n"
    printf "\n"
    printf "示例:\n"
    printf "  %s                      # 上传所有文件\n" "$0"
    printf "  %s -p meta-rules-dat    # 只上传 meta-rules-dat 项目\n" "$0"
    printf "  %s -p mihomo -r v1.19.12 # 只上传 mihomo 项目的 v1.19.12 版本\n" "$0"
    printf "  %s -f \"*.zip\"          # 只上传 zip 文件\n" "$0"
    printf "  %s -p mihomo -f \"*.deb\" # 只上传 mihomo 项目的 deb 文件\n" "$0"
    printf "\n"
    printf "功能:\n"
    printf "  自动扫描项目目录,将文件上传到GitHub Releases\n"
    printf "  跳过已存在的文件以节省流量\n"
}

# 列出所有可用的项目和版本
list_projects_and_versions() {
    log_info "可用的项目和版本:"
    echo ""
    
    for project_dir in */; do
        if [ -d "$project_dir" ] && [ -d "${project_dir}releases" ]; then
            project_name="${project_dir%/}"
            printf "%s%s:%s\n" "${BOLD}${GREEN}" "$project_name" "${RESET}"
            
            for version_dir in "${project_dir}releases"/*/; do
                if [ -d "$version_dir" ]; then
                    version_name=$(basename "$version_dir")
                    file_count=0
                    for file in "$version_dir"*; do
                        if [ -f "$file" ]; then
                            file_count=$((file_count + 1))
                        fi
                    done
                    printf "  - %s%s%s (%d 个文件)\n" "${CYAN}" "$version_name" "${RESET}" "$file_count"
                fi
            done
            echo ""
        fi
    done
}

# 主函数
main() {
    # 设置颜色
    setup_colors
    
    # 解析命令行参数
    VERBOSE=0
    PROJECT_FILTER=""
    VERSION_FILTER=""
    FILE_FILTER=""
    
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -p|--project)
                PROJECT_FILTER="$2"
                shift 2
                ;;
            -r|--version)
                VERSION_FILTER="$2"
                shift 2
                ;;
            -f|--file)
                FILE_FILTER="$2"
                shift 2
                ;;
            -l|--list)
                list_projects_and_versions
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    printf "%b======================================%b\n" "${BLUE}" "${RESET}"
    printf "%b    GitHub 文件上传脚本%b\n" "${GREEN}" "${RESET}"
    printf "%b======================================%b\n" "${BLUE}" "${RESET}"
    printf "\n"
    
    # 显示过滤条件
    if [ -n "$PROJECT_FILTER" ]; then
        log_info "项目过滤: $PROJECT_FILTER"
    fi
    if [ -n "$VERSION_FILTER" ]; then
        log_info "版本过滤: $VERSION_FILTER"
    fi
    if [ -n "$FILE_FILTER" ]; then
        log_info "文件过滤: $FILE_FILTER"
    fi
    if [ -z "$PROJECT_FILTER$VERSION_FILTER$FILE_FILTER" ]; then
        log_info "未设置过滤条件,将处理所有文件"
    fi
    printf "\n"
    
    # 检查依赖
    check_dependencies
    
    # 验证GitHub访问权限
    verify_github_access
    
    # 统计总文件数
    log_info "正在统计文件总数..."
    total_files=$(count_total_files "$PROJECT_FILTER" "$VERSION_FILTER" "$FILE_FILTER")
    if [ "$total_files" -eq 0 ]; then
        log_error "没有找到符合过滤条件的文件"
        log_info "使用 -l 参数查看可用的项目和版本"
        exit 1
    fi
    
    log_success "找到 $total_files 个文件需要处理"
    log_info "开始扫描并上传项目文件..."
    log_info "跳过已存在的文件以节省流量"
    printf "\n"
    
    # 查找所有项目
    current_file_index=0
    for project_dir in */; do
        # 跳过非目录项
        if [ ! -d "$project_dir" ]; then
            continue
        fi
        
        project_name="${project_dir%/}"
        
        # 项目过滤
        if [ -n "$PROJECT_FILTER" ] && [ "$project_name" != "$PROJECT_FILTER" ]; then
            continue
        fi
        
        # 检查是否有releases目录
        if [ ! -d "${project_dir}releases" ]; then
            continue
        fi
        
        log_info "处理项目: $project_name"
        printf "%b==============================%b\n" "${BLUE}" "${RESET}"
        
        # 处理每个版本
        for version_dir in "${project_dir}releases"/*/; do
            # 跳过非目录项
            if [ ! -d "$version_dir" ]; then
                continue
            fi
            
            version_name=$(basename "$version_dir")
            
            # 版本过滤
            if [ -n "$VERSION_FILTER" ] && [ "$version_name" != "$VERSION_FILTER" ]; then
                continue
            fi
            
            log_info "版本: $version_name"
            
            # 处理每个文件
            for file in "$version_dir"*; do
                # 跳过目录,只处理文件
                if [ ! -f "$file" ]; then
                    continue
                fi
                
                file_name=$(basename "$file")
                
                # 文件过滤
                if [ -n "$FILE_FILTER" ] && ! echo "$file_name" | grep -q "$FILE_FILTER"; then
                    continue
                fi
                
                current_file_index=$((current_file_index + 1))
                printf "%b------------------------------%b\n" "${CYAN}" "${RESET}"
                upload_file_with_path "$file" "$current_file_index" "$total_files"
                result=$?
                
                case $result in
                    0) 
                        total_success=$((total_success + 1))
                        log_success "上传成功 [$current_file_index/$total_files],继续处理下一个文件..."
                        ;;
                    1) 
                        total_error=$((total_error + 1))
                        log_error "上传失败 [$current_file_index/$total_files],但会继续处理其他文件..."
                        ;;
                    2) 
                        total_skip=$((total_skip + 1))
                        log_warning "文件已存在跳过 [$current_file_index/$total_files],继续处理下一个文件..."
                        ;;
                esac
            done
        done
        printf "\n"
    done
    
    printf "%b======================================%b\n" "${BLUE}" "${RESET}"
    printf "%b所有文件处理完成!%b\n" "${GREEN}" "${RESET}"
    printf "%b======================================%b\n" "${BLUE}" "${RESET}"
    printf "\n"
    printf "%b✓ 总计成功: %s 个文件%b\n" "${GREEN}" "$total_success" "${RESET}"
    printf "%b↷ 总计跳过: %s 个文件%b\n" "${YELLOW}" "$total_skip" "${RESET}"
    if [ $total_error -gt 0 ]; then
        printf "%b✗ 总计失败: %s 个文件%b\n" "${RED}" "$total_error" "${RESET}"
    else
        printf "%b✓ 总计失败: %s 个文件%b\n" "${GREEN}" "$total_error" "${RESET}"
    fi
    printf "\n"
    
    if [ $total_skip -gt 0 ]; then
        log_success "跳过 $total_skip 个已存在的文件,节省了流量和API调用次数"
    fi
    
    if [ $total_error -gt 0 ]; then
        log_error "有 $total_error 个文件上传失败,请检查错误信息"
    else
        log_success "所有文件处理完成,没有错误"
    fi
    
    printf "\n"
    log_info "可以在GitHub仓库查看上传的文件:"
    log_info "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases"
}

# 运行主函数
main "$@"
