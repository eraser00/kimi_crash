#!/bin/bash

export ANTHROPIC_BASE_URL=https://api.kimi.com/coding/
export ANTHROPIC_API_KEY=${YOUR_KIMI_API_KEY}

cp claude_conf/settings.json ~/.claude/settings.json

color_msg() {
    local color=$1
    shift  # 移除第一个参数，剩余全是消息内容
    local msg="$*"  # 将所有剩余参数合并为一条消息
    
    local code
    case $color in
        black)   code=30 ;;
        red)     code=31 ;;
        green)   code=32 ;;
        yellow)  code=33 ;;
        blue)    code=34 ;;
        magenta) code=35 ;;
        cyan)    code=36 ;;
        white)   code=37 ;;
        *)       code=37 ;;
    esac
    
    printf "\033[0;%dm%s\033[0m\n" "$code" "$msg"
}

# 快捷函数（修复：使用 "$@" 传递所有参数）
msg_red()    { color_msg red "$@"; }
msg_green()  { color_msg green "$@"; }
msg_yellow() { color_msg yellow "$@"; }
msg_blue()   { color_msg blue "$@"; }
msg_cyan()   { color_msg cyan "$@"; }

# 日志函数（修复）
log_info()  { color_msg cyan "[INFO] $*"; }
log_warn()  { color_msg yellow "[WARN] $*"; }
log_error() { color_msg red "[ERROR] $*"; }
log_ok()    { color_msg green "[OK] $*"; }

mvts() {
    [[ -d "$1" ]] || { echo "Usage: mvts <folder>"; return 1; }
    mv "$1" "$1_$(date +%Y%m%d_%H%M%S)"
}

copy_latest_claude_jsonl_compat() {
    local dest_dir="$1"
    local src_dir="$HOME/.claude/projects"
    
    # 使用 ls -t 排序（次优，但兼容性好）
    local latest_file
    latest_file=$(ls -t "$src_dir"/*/*.jsonl 2>/dev/null | head -1)
    
    [ -z "$latest_file" ] && { echo "No jsonl files found"; return 1; }
    
    cp "$latest_file" "$dest_dir/"
    echo "Copied: $latest_file"
}

root_dir=$(pwd)
log_dir="$HOME/log_kimi_crash"
mkdir -p $log_dir/log_succ
mkdir -p $log_dir/log_fail

check_fail() {
   if [[ $? -ne 0 ]]; then
     log_error "执行失败"
     log_error "失败检查项:" $1
     copy_latest_claude_jsonl_compat $log_dir/log_fail      
     cp -rf $2 $log_dir/log_fail
     mvts $log_dir/log_succ
     mvts $log_dir/log_fail
     exit 1
   fi
}

# ==================================== Step 0 ======================================

prompt=$(cat prompt/prompt5.txt)
log_info "Step0:" 
log_info $prompt

rm -rf run0
#rm -rf ~/.claude/projects/*
mkdir -p run0
run_dir=$(realpath run0)
cd run0
mkdir -p docker_build
# 锁定代码版本
git clone https://github.com/Tencent/libco.git && cd libco && cd -

docker ps | grep libco_dev | awk '{ print $1 }' | xargs docker stop || echo "Clear"
docker ps -a | grep "Created" | awk '{ print $1}' | xargs docker rm || echo "Clear"
docker ps -a | grep "Exited" | awk '{ print $1}' | xargs docker rm || echo "Clear"
docker rmi libco_dev || echo "Clear img" 
docker images | grep '<none>\s*<none>' | awk '{ print $3 }' | xargs docker rmi || echo "Clear"

cat $root_dir/prompt/prompt5.txt | claude --debug
check_fail "使用clang构建libco" $run_dir

docker run --pull never --rm libco_dev sh -c "find /workspace/libco -name '*.o' | head -n 10 | xargs nm | grep __clang_call_terminate"
check_fail "使用clang构建libco" $run_dir


docker run --pull never --rm libco_dev sh -c 'ls -lhtr /workspace/libco/install/libco.a'
check_fail "使用clang构建libco.a" $run_dir


docker run --pull never --rm libco_dev sh -c 'timeout 300 /workspace/libco/install/ut_co_resume'
check_fail "使用clang构建co_resume单元测试" $run_dir


#docker run --pull never --rm libco_dev sh -c "find /workspace/libco -name '*.gcno' | head -n 10 | grep 'co_rountine'"
#check_fail "使用clang构建覆盖率libco.a" $run_dir

#docker run --pull never --rm libco_dev sh -c "timeout 300 /workspace/libco/install/ut_co_resume && find /workspace/libco -name '*.gcda' | grep co_rountine"
#check_fail "生成co_resume覆盖率" $run_dir


# 这里我陷入了思维盲点，review 日志之后发现有一个情况是启用了LLVM的覆盖率实现而非gcov
# 应该增加检查, 兼容这种情况:
#docker run --pull never --rm libco_dev sh -c "timeout 300 /workspace/libco/install/ut_co_resume >/dev/null 2>&1 && find /workspace/libco -name '*.profraw' | xargs llvm-profdata merge -sparse -o /tmp/merged.profdata && llvm-cov show /workspace/libco/install/ut_co_resume -instr-profile=/tmp/merged.profdata -name-regex='co_resume'" | grep co_resume

# 运行单元测试并检查覆盖率（兼容 gcov 和 llvm-profraw）
docker run --pull never --rm libco_dev sh -c '
set -e
# 执行测试（超时 300 秒，保留输出便于调试）
timeout 300 /workspace/libco/install/ut_co_resume

# 方式1：检查 gcov 生成的 .gcda 文件
if find /workspace/libco -name "*.gcda" | grep -q co_resume; then
    exit 0
fi

# 方式2：检查 LLVM 生成的 .profraw 文件
profraw_files=$(find /workspace/libco -name "*.profraw")
if [ -n "$profraw_files" ]; then
    # 合并所有 .profraw 文件
    echo "$profraw_files" | xargs llvm-profdata merge -sparse -o /tmp/merged.profdata
    # 使用 llvm-cov 查看覆盖率，并检查是否包含 co_resume
    if llvm-cov show /workspace/libco/install/ut_co_resume \
         -instr-profile=/tmp/merged.profdata \
         -name-regex="co_resume" 2>/dev/null | grep -q co_resume; then
        exit 0
    fi
fi

# 两种方式均未找到 co_resume 覆盖率数据
exit 1
'

# 如果容器返回非零（即两种检查均失败），则调用 check_fail
if [ $? -ne 0 ]; then
    check_fail "生成co_resume覆盖率" "$run_dir"
fi


docker run --pull never -it --rm libco_dev cat /workspace/libco/ut_co_resume.cpp >src.cpp
check_fail "生成正确的co_resume单元测试" "$run_dir"

cat src.cpp | claude -p "查看这个单元测试源码当中是否包括了在co_routine当中创建co_routine的测试；包括的情况下输出<answer>yes</answer>否则输出<answer>no</answer>" > check.txt

grep -i '<answer>yes</answer>' check.txt
check_fail "生成正确的co_resume单元测试" "$run_dir"

# 正确的做法是设置一个claude code的hook脚本，在构建次数超过限制时、LLM调用docker rmi偷鸡时强制退出
# 但是下面这个简单检查也工作的很好，还可以过滤Dockerfile等文件都没改动直接重新执行的情况
if [[ $(docker images | grep -c '<none>\s*<none>') -gt 2 ]]; then
    false; check_fail "docker build构建次数超过限制" $run_dir
else
    log_info "没有多余docker build产物"
fi


log_ok "Step0 执行成功"
cd $root_dir
copy_latest_claude_jsonl_compat $log_dir/log_succ 

# ====================================  结束  ======================================
log_ok "所有执行成功"
mvts $log_dir/log_succ
mvts $log_dir/log_fail
exit 0
