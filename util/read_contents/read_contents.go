package main

import (
	zmq "github.com/pebbe/zmq4"
	"flag"
	"log"
	"os"
)

func main() {
	uri := flag.String("endpoint", "tcp://127.0.0.1:5572", "ZMQ URI of contents endpoint")
	flag.Parse()
	sock, err := zmq.NewSocket(zmq.REQ)
	if err != nil {
		log.Fatalf("Could not create ZMQ socket: %v", err)
	}
	err = sock.Connect(*uri)
	if err != nil {
		log.Fatalf("Could not connect to %s: %v", uri, err)
	}
	_, err = sock.Send("", 0)
	if err != nil {
		log.Fatalf("Could not send: %v", uri, err)
	}
	for {
		contents, err := sock.RecvBytes(0)
		if err != nil {
			log.Println(err)
		}
		if string(contents[:]) == "" {
			break
		}
		os.Stdout.Write(contents)
	}
}
