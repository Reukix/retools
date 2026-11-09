package main

import (
	"errors"
	"fmt"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"sort"
)

type mobileSinfReplicator interface {
	ReplicateSinf(appstore.ReplicateSinfInput) error
}

// Download returns licenses separately from the ZIP. The frontend must receive
// only the completed archive, with the indexed licenses written into SC_Info.
func finalizeMobileDownload(store mobileSinfReplicator, download appstore.DownloadOutput) (string, error) {
	if len(download.Sinfs) == 0 {
		return "", errors.New("商店没有返回解密所需的 SINF 许可，请重新获取安装包。")
	}
	licenses := append([]appstore.Sinf(nil), download.Sinfs...)
	sort.Slice(licenses, func(i, j int) bool { return licenses[i].ID < licenses[j].ID })
	for index, license := range licenses {
		if license.ID != int64(index) || len(license.Data) == 0 || len(license.DPInfo) != 0 {
			return "", errors.New("商店返回的 iPhone 许可索引或数据不完整。")
		}
	}
	if err := store.ReplicateSinf(appstore.ReplicateSinfInput{Sinfs: licenses, PackagePath: download.DestinationPath}); err != nil {
		return "", fmt.Errorf("合并商店许可失败：%w", err)
	}
	return download.DestinationPath, nil
}
