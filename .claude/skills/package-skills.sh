#!/usr/bin/env bash
# package-skills.sh — empaqueta JUNTAS las skills de ciclo de vida del clúster legacy EKS: legacy-eks-cluster (instala) y legacy-eks-uninstall (desinstala).
# Usage: package-skills.sh [directorio-de-salida]   -> <salida>/legacy-eks-skills-<fecha>.tar.gz  (por defecto el directorio actual)
# Instalación del paquete: tar -xzf legacy-eks-skills-*.tar.gz -C ~/.claude/skills   (o en <proyecto>/.claude/skills)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; OUT="${1:-$PWD}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
SKILLS=(legacy-eks-cluster legacy-eks-uninstall)
for s in "${SKILLS[@]}"; do [[ -f "$HERE/$s/SKILL.md" ]] || { echo "falta $HERE/$s/SKILL.md" >&2; exit 1; }; done
# antes de empaquetar, pasar las pruebas offline de ambas (no tocan AWS)
for s in "${SKILLS[@]}"; do
  [[ -x "$HERE/$s/tests/run-offline-tests.sh" ]] || continue
  echo ">> pruebas de $s"; "$HERE/$s/tests/run-offline-tests.sh" >/tmp/pkg-$s.log 2>&1 && echo "   OK ($(tail -1 /tmp/pkg-$s.log))" || { echo "   FALLAN las pruebas de $s (ver /tmp/pkg-$s.log): no se empaqueta" >&2; exit 1; }
done
TGZ="$OUT/legacy-eks-skills-$(date +%Y%m%d).tar.gz"
tar -czf "$TGZ" -C "$HERE" --exclude='__pycache__' --exclude='*.log' "${SKILLS[@]}"
echo "paquete: $TGZ"; tar -tzf "$TGZ" | awk -F/ '{print $1"/"$2}' | sort -u | head -20
