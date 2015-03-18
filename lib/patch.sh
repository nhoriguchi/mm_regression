# TODO: need support either FIXEDBY_SUBJECT=(empty) or FIXEDBY_COMMITID=(empty)
# case. This is imporant to filter testcase for non-mainline/stable tree

DEFAULT_START_POINT=02f8c6aee8df3cdc935e9bdd4f2d020306035dbe # v3.0

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
    local subject=
    local subjects="$2"
    local author="$3"
    local search_date="$4"
    local line=

    if ! git log -n1 $current > /dev/null 2>&1 ; then
        echo "given 'current branch' not exist."
        return 1
    fi
    if [ ! "$subjects" ] ; then
        echo "$FUNCNAME: need argument 'subjects'"
        return 1
    fi
    if [ "$author" ] ; then
        author="--author='$author'"
    fi
    if [ "$search_date" ] ; then
        search_date="--since='$search_date'"
    fi
    # echo git log --oneline $author $search_date $DEFAULT_START_POINT..$current >&2
    eval git log --oneline $author $search_date $DEFAULT_START_POINT..$current > $TMPF.patches
    while read subject ; do
        if ! grep "$subject" $TMPF.patches > /dev/null ; then
            return 1
        fi
    done <<<"$(echo $subjects | tr '|' '\n')"
    return 0
}

check_patch_applied() {
    local current=$1    # branch to be checked for inclusion of a given patch
                        # sometimes git tag is not pushed on the target machine,
                        # so using commit id might be more helpful.
    local subjects="$2" # subjects of the patch which is check to be included.
                        # You can set multiple patches with '|' separated subjects.
    local commit=$3     # (optional) commit ID of the patch which is check to be included
    local author="$4"   # (optional) patch'es author
    local search_date="$5" # (optional) date since which git-log search walks over

    if ! git log -n1 $current > /dev/null 2>&1 ; then
        echo "given 'current branch' not exist."
        return 1
    fi

    if [ "$subjects" ] ; then
        # "subjects only" search might be not enough because it might exist
        # patches with the same title, so if worried combine with author search
        if find_patch_applied $current "$subjects" "$author" "$search_date" > /dev/null ; then
            return 0
        else
            return 1
        fi
    else
        # search only with commit ID, this is not reliable because patches are
        # often be backported into stable tree, so don't fully trust this and
        # use "author & subjects" search
        #
        # git version must be >= 1.8
        echo "git merge-base --is-ancestor $commit $current"
        git merge-base --is-ancestor $commit $current
    fi
}

if [ $0 = $BASH_SOURCE ] ; then
    TMPF=$(mktemp)
    guess_distribution
    # mmotm-2015-03-04-16-59
    find_patch_applied 05b52c5e7abc "zram: support compaction" > /dev/null && echo true || echo false
    # v4.0-rc3
    check_patch_applied 9eccca084320 "mm: hwpoison: drop lru_add_drain_all() in __soft_offline_page()" 9ab3b598d2df && echo true || echo false
    # v3.19
    check_patch_applied bfa76d495765 "mm: hwpoison: drop lru_add_drain_all() in __soft_offline_page()" 9ab3b598d2df && echo true || echo false
    # v4.0-rc3
    check_patch_applied 9eccca084320 "mm: hwpoison: drop lru_add_drain_all() in __soft_offline_page()" 9ab3b598d2df "Naoya Horiguchi" && echo true || echo false
    check_patch_applied bfa76d495765 "mm: hwpoison: drop lru_add_drain_all() in __soft_offline_page()|hwpoison: call action_result() in failure path of hwpoison_user_mappings()|hwpoison: fix hugetlbfs/thp precheck in hwpoison_user_mappings()" "" "" "Jul 29 2014" && echo true || echo false
    check_patch_applied bfa76d495765 "hwpoison: call action_result() in failure path of hwpoison_user_mappings()|hwpoison: fix hugetlbfs/thp precheck in hwpoison_user_mappings()" "" "" "Jul 29 2014" && echo true || echo false
    rm /$TMPF.*
fi
