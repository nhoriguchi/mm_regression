# TODO: need support either FIXEDBY_SUBJECT=(empty) or FIXEDBY_COMMITID=(empty)
# case. This is imporant to filter testcase for non-mainline/stable tree


guess_distribution() {
    local ckernel=$(uname -r)

    if [[ "$ckernel" =~ \.fc ]] ; then
        echo fedora
    elif [[ "$ckernel" =~ \.el7 ]] ; then
        echo rhel7
    elif [[ "$ckernel" =~ \.el6 ]] ; then
        echo rhel6
    else
        echo upstream
    fi
}

# check_patch_applied current "patch_subject"
# assuming remote branch 'origin' point to Linus tree.
find_patch_applied() {
    local current=$1
    local subject="$2"
    local forkpoint=$(git merge-base $current origin/master)
    local line=

    [ "$forkpoint" ] || return 1
    line=$(git log --oneline $forkpoint..$current | grep "$subject")
    if [ "$line" ] ; then
        echo $line | cut -f1 -d' '
        return 0
    else
        return 1
    fi
}

# check_patch_applied current <commit> "patch_subject"
check_patch_applied() {
    local current=$1   # branch to be checked for inclusion of a given patch
    local subject="$2" # subject of the patch which is check to be included
    local commit=$3    # commit ID of the patch which is check to be included

    if ! git log -n1 $current > /dev/null ; then
        echo "given 'current branch' not exist."
        return 1
    fi

    if [ "$subject" ] && find_patch_applied $current "$subject" > /dev/null ; then
        return 0
    else
        # git version must be >= 1.8
        git merge-base --is-ancestor $commit $current
    fi
}

if [ $0 = $BASH_SOURCE ] ; then
    guess_distribution
    find_patch_applied mmotm-2015-03-04-16-59 "zram: support compaction" > /dev/null && echo true || echo false
    check_patch_applied v4.0-rc3 "mm: hwpoison: drop lru_add_drain_all() in __soft_offline_page()" 9ab3b598d2df && echo true || echo false
    check_patch_applied v3.19 "mm: hwpoison: drop lru_add_drain_all() in __soft_offline_page()" 9ab3b598d2df && echo true || echo false
fi
