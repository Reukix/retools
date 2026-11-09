package http

import (
	"context"
	"errors"
	gohttp "net/http"
	"testing"
	"time"
)

type retoolsBlockingExecutor struct{ started chan struct{} }

func (e retoolsBlockingExecutor) Send(request Request, _ []byte) (*gohttp.Response, error) {
	close(e.started)
	if request.Context == nil {
		return nil, errors.New("operation context was lost")
	}
	<-request.Context.Done()
	return nil, request.Context.Err()
}
func (e retoolsBlockingExecutor) Do(request *gohttp.Request) (*gohttp.Response, error) {
	<-request.Context().Done()
	return nil, request.Context().Err()
}

func TestRetoolsOperationCancellationReachesPendingHTTPRequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	executor := retoolsBlockingExecutor{started: make(chan struct{})}
	client := NewClient[map[string]any](Args{Context: ctx, Executor: executor})
	finished := make(chan error, 1)
	go func() {
		_, err := client.Send(Request{URL: "https://example.invalid", Method: MethodGET})
		finished <- err
	}()
	<-executor.started
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("lost cancellation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("request remained blocked after cancel")
	}
}

func TestRetoolsOperationCancellationAlsoStopsAnExplicitChildContext(t *testing.T){
    ctx,cancel:=context.WithCancel(context.Background());defer cancel()
    executor:=retoolsBlockingExecutor{started:make(chan struct{})}
    client:=NewClient[map[string]any](Args{Context:ctx,Executor:executor})
    finished:=make(chan error,1)
    go func(){_,err:=client.Send(Request{Context:context.Background(),URL:"https://example.invalid",Method:MethodGET});finished<-err}()
    <-executor.started;cancel()
    select{case err:=<-finished:if !errors.Is(err,context.Canceled){t.Fatalf("lost parent cancellation: %v",err)};case <-time.After(time.Second):t.Fatal("explicit request context ignored operation cancellation")}
}
