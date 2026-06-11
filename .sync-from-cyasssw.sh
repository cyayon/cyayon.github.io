#!/bin/sh

Src="../../codeberg.org/cyayon/cyasssw/"
Dst="../../github.com/cyayon.github.io/"
Index="README.md"

[ ! -d "$Src" ] && echo "FATAL: Src $Src not exist !" &&  exit 1
[ ! -f "${Src}/${Index}" ] && echo "FATAL: Index ${Src}/${Index} not exist !" &&  exit 1
[ ! -d "$Dst" ] && echo "FATAL: Dst $Dst not exist !" &&  exit 1

Src="$(cd "$Src" && pwd -P)" || exit 1
Dst="$(cd "$Dst" && pwd -P)" || exit 1

echo "Dummy:" 
#( cd "$Src" || exit 1 ; find . -mindepth 1 -maxdepth 1 -type d ! -name ".*" -print0 | rsync -avhrni --from0 --files-from=- --exclude='.DS_Store' ./ "${Dst}/" )
( cd "$Src" || exit 1 ; find . -path './.*' -prune -o -type f -name '*.md' -print0 | rsync -avhni --from0 --files-from=- ./ "${Dst}/" )
echo
echo "continue ?" ; read a
#( cd "$Src" || exit 1 ; find . -mindepth 1 -maxdepth 1 -type d ! -name ".*" -print0 | rsync -avhri --from0 --files-from=- --exclude='.DS_Store' ./ "${Dst}/" )
( cd "$Src" || exit 1 ; find . -path './.*' -prune -o -type f -name '*.md' -print0 | rsync -avhi --from0 --files-from=- ./ "${Dst}/" )

echo "Index ${Src}/${Index} ${Dst}/${Index}"
#cp "${Src}/${Index}" "${Dst}/${Index}" && sed -i "s/\.md)/)/g" "${Dst}/${Index}"
sed "s/\.md)/)/g" "${Src}/${Index}" > "${Dst}/${Index}"

