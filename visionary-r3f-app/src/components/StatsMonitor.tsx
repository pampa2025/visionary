import { useEffect, useRef } from 'react'
import Stats from 'stats.js'
import { useFrame } from '@react-three/fiber'

export function StatsMonitor() {
  const statsRef = useRef<Stats | null>(null)

  useEffect(() => {
    const stats = new Stats()
    stats.showPanel(0) // 0: fps, 1: ms, 2: mb, 3+: custom
    document.body.appendChild(stats.dom)
    
    // Style positioning
    stats.dom.style.position = 'absolute'
    stats.dom.style.top = '0px'
    stats.dom.style.left = '0px'
    stats.dom.style.zIndex = '9999'

    statsRef.current = stats

    return () => {
      document.body.removeChild(stats.dom)
      statsRef.current = null
    }
  }, [])

  useFrame(() => {
    statsRef.current?.update()
  })

  return null
}
