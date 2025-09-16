package main

import (
	"flag"
	"log"

	apphttp "github.com/enginrect/lbaas-agent/ovs-agent/internal/app/http"
)

func main() {
	addr := flag.String("bind", ":9406", "bind address, e.g. 0.0.0.0:9406")
	flag.Parse()

	srv, err := apphttp.NewServer()
	if err != nil {
		log.Fatalf("failed to init: %v", err)
	}

	if err := srv.Start(*addr); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
