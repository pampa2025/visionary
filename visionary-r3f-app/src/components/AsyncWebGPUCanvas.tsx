import React, { useState, useEffect, useCallback } from 'react'
import { Canvas, CanvasProps } from '@react-three/fiber'
// @ts-ignore
import { WebGPURenderer } from 'three/webgpu'

interface AsyncWebGPUCanvasProps extends Omit<CanvasProps, 'onCreated'> {
  fallback?: React.ReactNode
  loading?: React.ReactNode
  onInitialized?: (renderer: WebGPURenderer) => void
  onInitError?: (error: Error) => void
  onCreated?: CanvasProps['onCreated']
}

export function AsyncWebGPUCanvas({
  children,
  fallback,
  loading,
  onInitialized,
  onInitError,
  ...props
}: AsyncWebGPUCanvasProps) {
  const [status, setStatus] = useState<'checking' | 'initializing' | 'ready' | 'error'>('checking')
  const [errorMessage, setErrorMessage] = useState<string>('')

  // 1. Check WebGPU support first
  useEffect(() => {
    const checkSupport = async () => {
      if (!navigator.gpu) {
        setStatus('error')
        setErrorMessage('WebGPU is not supported in this browser. Try Chrome 113+ or Edge.')
        return
      }

      try {
        const adapter = await navigator.gpu.requestAdapter({
          powerPreference: 'high-performance'
        })
        
        if (!adapter) {
          throw new Error('No WebGPU adapter found')
        }
        
        setStatus('initializing')
      } catch (error) {
        console.error('WebGPU support check failed:', error)
        setStatus('error')
        setErrorMessage(error instanceof Error ? error.message : 'Unknown error')
        onInitError?.(error instanceof Error ? error : new Error('WebGPU check failed'))
      }
    }

    checkSupport()
  }, [onInitError])

  // 2. Create and initialize renderer
  // @ts-ignore
  const createRenderer = useCallback((params: any) => {
    // R3F passes DefaultGLProps which contains the canvas
    const canvas = params.canvas || params
    
    const renderer = new WebGPURenderer({
      canvas,
      antialias: true,
      alpha: true,
      powerPreference: 'high-performance'
    })

    renderer.init().then(() => {
      renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
      setStatus('ready')
      onInitialized?.(renderer)
      console.log('WebGPU initialized successfully')
    }).catch((error: Error) => {
      console.error('WebGPU initialization failed:', error)
      setStatus('error')
      setErrorMessage(error.message)
      onInitError?.(error)
    })

    return renderer
  }, [onInitialized, onInitError])

  // Error State
  if (status === 'error') {
    return (
      <div className="webgpu-error" style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100%',
        padding: '20px',
        textAlign: 'center',
        background: '#1a1a1a',
        color: '#fff'
      }}>
        <h3>⚠️ WebGPU Initialization Failed</h3>
        <p style={{ color: '#ff6b6b', margin: '10px 0' }}>{errorMessage}</p>
        {fallback || (
          <div style={{ marginTop: '20px' }}>
            <p>Suggestions:</p>
            <ul style={{ textAlign: 'left', display: 'inline-block' }}>
              <li>Use Chrome 113+ or Edge 113+</li>
              <li>Enable <code>#enable-unsafe-webgpu</code> in <code>chrome://flags</code></li>
              <li>Ensure HTTPS or localhost</li>
            </ul>
          </div>
        )}
      </div>
    )
  }

  // Checking Support State
  if (status === 'checking') {
    return (
      <div style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100%',
        background: '#1a1a1a',
        color: '#fff'
      }}>
        {loading || <div>Checking WebGPU Support...</div>}
      </div>
    )
  }

  // Initializing or Ready State
  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      {status === 'initializing' && (
        <div style={{
          position: 'absolute',
          inset: 0,
          zIndex: 10,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: '#1a1a1a',
          color: '#fff'
        }}>
          {loading || <div>Initializing WebGPU Renderer...</div>}
        </div>
      )}
      <Canvas
        gl={createRenderer}
        onCreated={({ gl }) => {
           // Any additional setup if needed
        }}
        {...props}
      >
        {status === 'ready' ? children : null}
      </Canvas>
    </div>
  )
}
