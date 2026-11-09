#!/usr/bin/env python3
"""Package our built helper as a resource; never signs or executes the helper."""
import os
from pathlib import Path
import zipfile

products = Path(os.environ['BUILT_PRODUCTS_DIR'])
app = products / 'RetoolsDecryptHelper.app'
destination = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'DecryptHelperTemplate.ipa'
destination.parent.mkdir(parents=True, exist_ok=True)
temporary = destination.with_suffix('.tmp')
with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.rglob('*')):
        if file.is_symlink():
            raise RuntimeError('Helper template contains a symlink')
        if file.is_file():
            archive.write(file, 'Payload/RetoolsDecryptHelper.app/' + file.relative_to(app).as_posix())
temporary.replace(destination)
