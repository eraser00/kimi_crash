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

prompt=$(cat prompt/prompt0.txt)
log_info "Step0:" 
log_info $prompt

rm -rf run0
#rm -rf ~/.claude/projects/*
mkdir -p run0
run_dir=$(realpath run0)
cd run0
mkdir -p docker_build
# 锁定代码版本
git clone https://github.com/mlc-ai/xgrammar.git && cd xgrammar && git checkout d0d7fac906a730d529e29274ba6447685474bf2a && cd -

docker ps -a | grep "Created" | awk '{ print $1}' | xargs docker rm || echo "Clear"
docker ps -a | grep "Exited" | awk '{ print $1}' | xargs docker rm || echo "Clear"

cat $root_dir/prompt/prompt0.txt | claude --debug -p
# 为了加速执行，首次测试成功后可以跳过这个阶段
#cat $root_dir/prompt/prompt0_fake.txt | claude --debug -p
check_fail "使用clang构建xgrammar" $run_dir

docker run --rm xgrammar_dev sh -c "find /workspace/xgrammar -name '*.o' | head -n 10 | xargs nm | grep __clang_call_terminate"
check_fail "使用clang构建xgrammar" $run_dir

docker run --rm xgrammar_dev sh -c 'pip list | grep xgrammar | grep /workspace/xgrammar'
check_fail "使用clang构建xgrammar, 检查xgrammar安装" $run_dir

log_ok "Step0 执行成功"
cd $root_dir
#copy_latest_claude_jsonl_compat $log_dir/log_succ 
rm -rf run0

# ==================================== Step 1 ======================================

prompt=$(cat prompt/prompt1.txt)
log_info "Step0:" 
log_info $prompt
root_dir=$(pwd)

rm -rf run1
#rm -rf ~/.claude/projects/*
mkdir -p run1
run_dir=$(realpath run1)
cd run1

docker ps | grep xgrammar_cov | awk '{ print $1 }' | xargs docker stop || echo "Clear"
docker ps -a | grep "Created" | awk '{ print $1}' | xargs docker rm || echo "Clear"
docker ps -a | grep "Exited" | awk '{ print $1}' | xargs docker rm || echo "Clear"
docker rmi xgrammar_cov || echo "Clear img" 
docker images | grep '<none>\s*<none>' | awk '{ print $3 }' | xargs docker rmi || echo "Clear"


# 这里不使用-p方便调试
cat $root_dir/prompt/prompt1.txt | claude --debug 
check_fail "使用clang构建覆盖率版本xgrammar" $run_dir

docker run --rm xgrammar_cov:latest bash -c "python3 -c 'import xgrammar' 2>&1 > /dev/null && find /workspace/xgrammar/build -name '*.gcda'" | grep -E 'gcda$'
check_fail "使用clang构建覆盖率版本xgrammar, 实际可以生成覆盖率文件" $run_dir


docker run --rm xgrammar_cov:latest bash -c "find /workspace/xgrammar/ -name '*.gcda' | xargs rm -f ; pytest tests/python/test_grammar_compiler.py ; find /workspace/xgrammar/build -name '*.gcda'" | grep -E 'gcda$' | grep 'grammar'
check_fail "使用clang构建覆盖率版本xgrammar, 实际可以生成覆盖率文件" $run_dir

# 正确的做法是设置一个claude code的hook脚本，在构建次数超过限制时、LLM调用docker rmi偷鸡时强制退出
# 但是下面这个简单检查也工作的很好，还可以过滤Dockerfile等文件都没改动直接重新执行的情况
if [[ $(docker images | grep -c '<none>\s*<none>') -gt 1 ]]; then
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
