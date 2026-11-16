//go:build !windows

package main

func lockForTest(dir string) (func(), bool, error) { return lockInstance(dir) }
