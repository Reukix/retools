package appstore

import (
	"context"
	"fmt"

	"github.com/majd/ipatool/v2/internal/sap"
	"github.com/majd/ipatool/v2/pkg/http"
)

type SAPConfig struct {
	AuthEndpoint   string
	SetupURL       string
	CertificateURL string
	Version        uint32
}

type ActionSigner interface {
	http.ActionSigner
	Close() error
}

type ActionSignerFactory func(config SAPConfig, machineID []byte) (ActionSigner, error)

func frameworkActionSignerFactory(client http.Executor) ActionSignerFactory {
	return frameworkActionSignerFactoryWithContext(client, context.Background())
}

func frameworkActionSignerFactoryWithContext(client http.Executor, ctx context.Context) ActionSignerFactory {
	return func(config SAPConfig, machineID []byte) (ActionSigner, error) {
		retoolsProgress("正在建立商店安全会话…")
		signer, err := sap.NewSigner(ctx, sap.Config{SetupURL: config.SetupURL, CertificateURL: config.CertificateURL, Version: config.Version, HardwareID: machineID, HTTPClient: client})
		if err != nil {
			return nil, fmt.Errorf("create SAP signer: %w", err)
		}

		return signer, nil
	}
}
