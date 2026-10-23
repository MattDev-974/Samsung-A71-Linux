#!/usr/bin/env bash
# shellcheck shell=bash
#
# preflight.sh - prediagnostic non destructif (phase 1).
#
# Ce fichier est une BIBLIOTHEQUE : il definit run_preflight() et n'est pas
# destine a etre execute directement (le lancement direct est refuse avec un
# message explicite). install.sh le source, ce qui garantit :
#   * un seul common.sh ;
#   * un seul jeu de traps ;
#   * un seul journal (LOG_FILE partage, deja cree par install.sh).
#
# run_preflight <action> avec action parmi : check | build | sd | flash.
# Chaque action a son propre jeu d'outils BLOQUANTS ; tout le reste est
# informatif. Le prediagnostic ne installe rien, ne telecharge rien, ne compile
# rien, ne monte rien, n'accede pas au telephone.
#
# Retour : 0 si aucune erreur bloquante, 1 sinon.

# Refus du lancement direct : ce fichier est une bibliotheque.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'preflight.sh est une bibliotheque interne : utilise ./install.sh --check\n' >&2
    exit 2
fi

pf_errors=0
pf_warnings=0

pf_ok() {
    printf '%s[OK]%s %s\n' "$C_OK" "$C_RESET" "$*"
    logfile_only "$*"
}
pf_warn() {
    pf_warnings=$((pf_warnings + 1))
    printf '%s[AVERTISSEMENT]%s %s\n' "$C_WARN" "$C_RESET" "$*"
    logfile_only "AVERTISSEMENT: $*"
}
pf_err() {
    pf_errors=$((pf_errors + 1))
    printf '%s[ERREUR]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2
    logfile_only "ERREUR: $*"
}
pf_info() {
    printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"
    logfile_only "$*"
}

# Verifie un ensemble d'outils ; mode "blocking" ou "info".
pf_check_tools() {
    local blocking=$1 label=$2 missing="" c
    shift 2
    for c in "$@"; do
        have "$c" || missing="$missing $c"
    done
    if [ -z "$missing" ]; then
        pf_ok "$label : tous presents"
    elif [ "$blocking" = "1" ]; then
        pf_err "$label : manquants ->$missing"
    else
        pf_info "$label : non requis en phase 1, manquants ->$missing"
    fi
}

run_preflight() {
    local action=${1:-check}

    case "$action" in
        check | build | sd | flash) ;;
        *)
            pf_err "action inconnue : $action (check|build|sd|flash)"
            return 1
            ;;
    esac

    pf_errors=0
    pf_warnings=0

    printf '\n%sPrediagnostic (action : %s)%s\n' "$C_INFO" "$action" "$C_RESET"
    printf '%s\n' '---------------------------------------------'
    logfile_only "Prediagnostic (action : $action)"

    # --- 1. systeme hote ---------------------------------------------------
    local host_os host_arch
    host_os=$(uname -s 2>/dev/null || echo inconnu)
    host_arch=$(uname -m 2>/dev/null || echo inconnu)
    if [ "$host_os" = "Linux" ]; then
        pf_ok "Hote : Linux $host_arch"
    else
        pf_err "Hote non pris en charge : $host_os (Linux requis)"
    fi

    case "$host_arch" in
        x86_64 | amd64) pf_info "Toolchain projet : hote x86_64 (Bootlin)" ;;
        aarch64 | arm64) pf_warn "Hote arm64 : la toolchain Bootlin x86_64 ne s'executera pas (mode --system-toolchain a prevoir)" ;;
        *) pf_warn "Architecture hote non validee : $host_arch" ;;
    esac

    # --- 2. outils du socle (bloquants pour toutes les actions) ------------
    pf_check_tools 1 "Socle (bash/awk/sed/grep/df/uname/stat)" bash awk sed grep df uname stat
    if [ "$pf_errors" -gt 0 ]; then
        # Sans ces outils, la suite du diagnostic n'est pas fiable : on s'arrete.
        printf '%sResultat : %d erreur(s), %d avertissement(s) - action "%s" bloquee%s\n\n' \
            "$C_ERR" "$pf_errors" "$pf_warnings" "$action" "$C_RESET"
        logfile_only "Resultat : $pf_errors erreur(s) - outils du socle manquants"
        return 1
    fi

    # --- 3. ressources -----------------------------------------------------
    local free_kib free_gib mem_kib mem_gib cpus
    free_kib=$(df -Pk "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "${free_kib:-}" ]; then
        free_gib=$((free_kib / 1024 / 1024))
        if [ "$free_gib" -ge 15 ]; then
            pf_ok "Espace libre dans le depot : ${free_gib} Gio"
        elif [ "$free_gib" -ge 5 ]; then
            pf_warn "Espace libre faible : ${free_gib} Gio (15 Gio recommandes pour noyau + rootfs)"
        else
            pf_err "Espace insuffisant : ${free_gib} Gio (5 Gio minimum)"
        fi
    else
        pf_warn "Espace libre : indetermine"
    fi

    mem_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")
    if [ -n "$mem_kib" ]; then
        mem_gib=$((mem_kib / 1024 / 1024))
        if [ "$mem_gib" -ge 4 ]; then
            pf_ok "RAM disponible : ${mem_gib} Gio"
        else
            pf_warn "RAM disponible faible : ${mem_gib} Gio (4 Gio recommandes)"
        fi
    else
        pf_info "RAM disponible : indeterminee"
    fi

    cpus=$(nproc 2>/dev/null || echo 1)
    pf_info "Processeurs disponibles : $cpus"

    # --- 4. outils par action ---------------------------------------------
    case "$action" in
        build)
            pf_check_tools 1 "Build (git/make/python3/tar/gzip/cpio/sha256sum)" \
                git make python3 tar gzip cpio sha256sum
            pf_check_tools 0 "Build (facultatifs)" curl wget dtc xz zstd
            ;;
        sd)
            pf_check_tools 1 "MicroSD (lsblk/findmnt/sfdisk/mkfs.ext4/blockdev)" \
                lsblk findmnt sfdisk mkfs.ext4 blockdev
            pf_check_tools 0 "MicroSD (facultatifs)" partprobe wipefs
            ;;
        flash)
            pf_check_tools 1 "Flash (heimdall)" heimdall
            pf_check_tools 0 "Flash (facultatifs)" lsusb
            ;;
        check)
            pf_check_tools 0 "Build (requis plus tard)" \
                git make python3 tar gzip cpio sha256sum
            pf_check_tools 0 "MicroSD (requis plus tard)" \
                lsblk findmnt sfdisk mkfs.ext4 blockdev
            pf_check_tools 0 "Flash (requis plus tard)" heimdall lsusb
            ;;
    esac

    # --- 5. elements informatifs ------------------------------------------
    if have qemu-aarch64-static; then
        pf_info "QEMU user-static present : chroot aarch64 possible (phase 3)"
    else
        pf_info "QEMU user-static absent : chroot aarch64 indisponible (phase 3 pourra s'en passer)"
    fi
    if have aarch64-linux-gnu-gcc; then
        pf_info "Compilateur croise systeme present (option future --system-toolchain)"
    else
        pf_info "Compilateur croise systeme absent (toolchain projet non encore telechargee)"
    fi
    if have shellcheck; then
        pf_info "ShellCheck present"
    else
        pf_info "ShellCheck absent : tests statiques non executes"
    fi

    # --- 6. manifeste (validation unique) ---------------------------------
    if [ ! -f "$MANIFEST" ]; then
        pf_err "Manifeste absent : $MANIFEST"
    elif ! manifest_validate "$MANIFEST"; then
        pf_err "Manifeste invalide : $MANIFEST (voir le diagnostic ci-dessus)"
    else
        pf_ok "Manifeste valide : $MANIFEST"
        local ver rc=0
        ver=$(manifest_get "$MANIFEST" "project.version") || rc=$?
        if [ "$rc" -eq 0 ] && ! is_todo_value "$ver"; then
            pf_ok "Version du projet : $ver"
        elif [ "$rc" -eq 1 ]; then
            pf_err "project.version absente du manifeste"
        else
            pf_err "project.version non resolue"
        fi
        local todo
        if ! todo=$(manifest_todo_keys "$MANIFEST"); then
            pf_err "impossible de relire les valeurs TODO du manifeste"
            todo=""
        fi
        if [ -n "$todo" ]; then
            pf_warn "Valeurs non resolues (TODO_*) - elles ne bloquent que leur etape :"
            local k
            for k in $todo; do
                pf_info "  - $k"
            done
        else
            pf_ok "Aucune valeur TODO_*"
        fi
    fi

    # --- 7. arborescence ---------------------------------------------------
    local d
    for d in scripts docs base dist initramfs; do
        if [ -d "$REPO_ROOT/$d" ]; then
            pf_info "Repertoire present : $d/"
        else
            pf_info "Repertoire absent : $d/"
        fi
    done

    if a71_dir_has_entries "$REPO_ROOT/dist"; then
        pf_warn "dist/ contient des artefacts legacy non reproductibles (la nouvelle chaine ne les utilise pas)"
    fi

    # --- resume ------------------------------------------------------------
    printf '%s\n' '---------------------------------------------'
    if [ "$pf_errors" -gt 0 ]; then
        printf '%sResultat : %d erreur(s), %d avertissement(s) - action "%s" bloquee%s\n\n' \
            "$C_ERR" "$pf_errors" "$pf_warnings" "$action" "$C_RESET"
        logfile_only "Resultat : $pf_errors erreur(s), $pf_warnings avertissement(s) - action $action bloquee"
        return 1
    fi
    printf '%sResultat : aucun blocage, %d avertissement(s)%s\n\n' \
        "$C_OK" "$pf_warnings" "$C_RESET"
    logfile_only "Resultat : aucun blocage, $pf_warnings avertissement(s)"
    return 0
}
