package controller

import (
	"context"
	"fmt"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	reconcile "sigs.k8s.io/controller-runtime/pkg/reconcile"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"

	kcpv1alpha1 "cogniteo.io/users/api/v1alpha1"
)

type fakeCluster struct {
	client client.Client
}

func (f *fakeCluster) GetClient() client.Client {
	return f.client
}

type fakeManager struct {
	cluster mcmanager.Cluster
	err     error
}

func (f *fakeManager) GetCluster(ctx context.Context, name string) (mcmanager.Cluster, error) {
	return f.cluster, f.err
}

func TestUserReconciler_Reconcile(t *testing.T) {
	scheme := runtime.NewScheme()
	clientgoscheme.AddToScheme(scheme)
	if err := kcpv1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("failed to add kcpv1alpha1 scheme: %v", err)
	}

	userName := "test-user"
	userNamespace := "default"
	namespacedName := types.NamespacedName{Name: userName, Namespace: userNamespace}

	t.Run("cluster retrieval failure", func(t *testing.T) {
		mgr := &fakeManager{err: fmt.Errorf("cluster not found")}
		r := &UserReconciler{Scheme: scheme, Manager: mgr}
		_, err := r.Reconcile(context.Background(), mcreconcile.Request{
			ClusterName: "cluster1",
			Request:     reconcile.Request{NamespacedName: namespacedName},
		})
		if err == nil || err.Error() != "failed to get cluster: cluster not found" {
			t.Errorf("expected error from GetCluster, got %v", err)
		}
	})

	t.Run("resource not found", func(t *testing.T) {
		fakeClient := fake.NewClientBuilder().WithScheme(scheme).Build()
		mgr := &fakeManager{cluster: &fakeCluster{client: fakeClient}}
		r := &UserReconciler{Scheme: scheme, Manager: mgr}
		result, err := r.Reconcile(context.Background(), mcreconcile.Request{
			ClusterName: "cluster1",
			Request:     reconcile.Request{NamespacedName: namespacedName},
		})
		if err != nil {
			t.Errorf("expected no error, got %v", err)
		}
		if result != ctrl.Result{} {
			t.Errorf("expected empty result, got %v", result)
		}
	})

	t.Run("successful reconciliation", func(t *testing.T) {
		initialUser := &kcpv1alpha1.User{
			ObjectMeta: metav1.ObjectMeta{
				Name:      userName,
				Namespace: userNamespace,
			},
		}
		fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(initialUser).Build()
		mgr := &fakeManager{cluster: &fakeCluster{client: fakeClient}}
		r := &UserReconciler{Scheme: scheme, Manager: mgr}
		_, err := r.Reconcile(context.Background(), mcreconcile.Request{
			ClusterName: "cluster1",
			Request:     reconcile.Request{NamespacedName: namespacedName},
		})
		if err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
		updatedUser := &kcpv1alpha1.User{}
		if err := fakeClient.Get(context.Background(), namespacedName, updatedUser); err != nil {
			t.Fatalf("failed to get updated user: %v", err)
		}
		ts, ok := updatedUser.Annotations["kcp.cogniteo.io/lastReconciledAt"]
		if !ok {
			t.Errorf("expected annotation lastReconciledAt, got %v", updatedUser.Annotations)
		} else {
			if _, err := time.Parse(time.RFC3339, ts); err != nil {
				t.Errorf("annotation lastReconciledAt not RFC3339: %v", err)
			}
		}
	})
}
