// Termweb Offscreen Document - Handles tabCapture frame processing with WebRTC DataChannel
// Signaling: Extension → Zig via console.log, Zig → Extension via polling window.__termwebRtcSignal
// Frame data flows over WebRTC DataChannel

const DEFAULT_FPS = 30;
const SIGNAL_POLL_INTERVAL = 50; // ms
const MAX_FPS = 120;
const MIN_FPS = 5;

let captureStream = null;
let captureVideo = null;
let captureCanvas = null;
let captureCtx = null;
let captureInterval = null;
let currentFps = DEFAULT_FPS;
let isCapturing = false;

// WebRTC state
let peerConnection = null;
let dataChannel = null;
let dataChannelOpen = false;

// ICE servers (none needed for local connection)
const rtcConfig = {
  iceServers: []
};

// Send signaling message to Zig via injected binding (CDP Runtime.bindingCalled)
// Falls back to console.log if binding not available
function sendSignaling(msg) {
  const data = JSON.stringify(msg);
  if (typeof window.__termwebRtcSignal === 'function') {
    window.__termwebRtcSignal(data);
  } else {
    // Fallback: use console.log with prefix (intercepted by CDP)
    console.log('__TERMWEB_RTC__:' + data);
  }
}

// Create WebRTC peer connection and data channel
async function createPeerConnection() {
  closePeerConnection();

  console.log('__TERMWEB_CAPTURE__:creating_peer_connection');
  peerConnection = new RTCPeerConnection(rtcConfig);

  // Create data channel for frames
  dataChannel = peerConnection.createDataChannel('frames', {
    ordered: false,      // Don't need ordering for frames
    maxRetransmits: 0    // Unreliable for low latency
  });

  dataChannel.binaryType = 'arraybuffer';

  dataChannel.onopen = () => {
    console.log('__TERMWEB_CAPTURE__:datachannel_open');
    dataChannelOpen = true;

    // Start capture now that channel is open
    requestCapture();
  };

  dataChannel.onclose = () => {
    console.log('__TERMWEB_CAPTURE__:datachannel_closed');
    dataChannelOpen = false;
  };

  dataChannel.onerror = (e) => {
    console.log('__TERMWEB_CAPTURE__:datachannel_error:' + (e.message || 'unknown'));
  };

  // ICE candidate handler
  peerConnection.onicecandidate = (event) => {
    if (event.candidate) {
      sendSignaling({
        type: 'candidate',
        candidate: event.candidate.candidate,
        mid: event.candidate.sdpMid || '0'
      });
    }
  };

  // Connection state handler
  peerConnection.onconnectionstatechange = () => {
    console.log('__TERMWEB_CAPTURE__:connection_state:' + peerConnection.connectionState);
    if (peerConnection.connectionState === 'failed' || peerConnection.connectionState === 'disconnected') {
      dataChannelOpen = false;
    }
  };

  // Create and send offer
  try {
    const offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);

    console.log('__TERMWEB_CAPTURE__:sending_offer');
    sendSignaling({
      type: 'offer',
      sdp: offer.sdp,
      sdpType: offer.type
    });
  } catch (e) {
    console.log('__TERMWEB_CAPTURE__:offer_error:' + e.message);
  }
}

// Close peer connection
function closePeerConnection() {
  dataChannelOpen = false;

  if (dataChannel) {
    dataChannel.close();
    dataChannel = null;
  }

  if (peerConnection) {
    peerConnection.close();
    peerConnection = null;
  }
}

// Handle signaling messages from Zig (via chrome.runtime.sendMessage)
async function handleSignaling(msg) {
  if (msg.type === 'answer' && peerConnection) {
    console.log('__TERMWEB_CAPTURE__:received_answer');
    try {
      await peerConnection.setRemoteDescription({
        type: msg.sdpType || 'answer',
        sdp: msg.sdp
      });
      console.log('__TERMWEB_CAPTURE__:answer_set');
    } catch (e) {
      console.log('__TERMWEB_CAPTURE__:answer_error:' + e.message);
    }
  } else if (msg.type === 'candidate' && peerConnection) {
    try {
      await peerConnection.addIceCandidate({
        candidate: msg.candidate,
        sdpMid: msg.mid
      });
    } catch (e) {
      console.log('__TERMWEB_CAPTURE__:ice_error:' + e.message);
    }
  } else if (msg.type === 'set_fps' && typeof msg.fps === 'number') {
    const newFps = Math.max(MIN_FPS, Math.min(MAX_FPS, msg.fps));
    if (newFps !== currentFps) {
      currentFps = newFps;
      if (isCapturing) {
        restartCaptureLoop();
      }
    }
  } else if (msg.type === 'start_rtc') {
    // Zig is ready, create peer connection
    console.log('__TERMWEB_CAPTURE__:start_rtc_received');
    await createPeerConnection();
  }
}

// Request capture from background script
function requestCapture() {
  console.log('__TERMWEB_CAPTURE__:requesting_capture');
  chrome.runtime.sendMessage({ type: 'REQUEST_STREAM_ID' }, (response) => {
    if (response && response.streamId) {
      console.log('__TERMWEB_CAPTURE__:got_stream_id');
      startCaptureWithStreamId(response.streamId);
    } else {
      console.log('__TERMWEB_CAPTURE__:no_stream_id:' + (response?.error || 'unknown'));
    }
  });
}

// Start capture with stream ID from background
async function startCaptureWithStreamId(streamId) {
  if (isCapturing) {
    stopCapture();
  }

  try {
    // Get media stream using the stream ID from tabCapture
    captureStream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        mandatory: {
          chromeMediaSource: 'tab',
          chromeMediaSourceId: streamId,
          maxFrameRate: MAX_FPS,
          minFrameRate: MIN_FPS
        }
      }
    });

    if (!captureStream) {
      console.log('__TERMWEB_CAPTURE__:stream_failed');
      return false;
    }

    console.log('__TERMWEB_CAPTURE__:got_stream');

    // Log stream resolution
    const videoTrack = captureStream.getVideoTracks()[0];
    const settings = videoTrack.getSettings();
    console.log('__TERMWEB_CAPTURE__:resolution:' + settings.width + 'x' + settings.height);

    // Set up video element
    captureVideo = document.createElement('video');
    captureVideo.srcObject = captureStream;
    captureVideo.muted = true;
    captureVideo.play();

    await new Promise((resolve) => {
      captureVideo.onloadedmetadata = resolve;
    });

    const width = captureVideo.videoWidth;
    const height = captureVideo.videoHeight;
    console.log('__TERMWEB_CAPTURE__:video_size:' + width + 'x' + height);

    // Set up canvas for frame capture
    captureCanvas = document.createElement('canvas');
    captureCtx = captureCanvas.getContext('2d', { willReadFrequently: true });

    isCapturing = true;
    startCaptureLoop();

    console.log('__TERMWEB_CAPTURE__:started');
    return true;
  } catch (e) {
    console.log('__TERMWEB_CAPTURE__:capture_error:' + e.message);
    return false;
  }
}

function stopCapture() {
  isCapturing = false;

  if (captureInterval) {
    clearInterval(captureInterval);
    captureInterval = null;
  }

  if (captureStream) {
    captureStream.getTracks().forEach(track => track.stop());
    captureStream = null;
  }

  if (captureVideo) {
    captureVideo.pause();
    captureVideo.srcObject = null;
    captureVideo = null;
  }

  captureCanvas = null;
  captureCtx = null;
}

function startCaptureLoop() {
  if (captureInterval) {
    clearInterval(captureInterval);
  }

  const intervalMs = Math.floor(1000 / currentFps);

  captureInterval = setInterval(() => {
    if (!isCapturing || !captureVideo || !captureCtx) {
      return;
    }

    // Check if data channel is open
    if (!dataChannelOpen || !dataChannel) {
      return;
    }

    const width = captureVideo.videoWidth;
    const height = captureVideo.videoHeight;

    if (width === 0 || height === 0) {
      return;
    }

    if (captureCanvas.width !== width || captureCanvas.height !== height) {
      captureCanvas.width = width;
      captureCanvas.height = height;
    }

    captureCtx.drawImage(captureVideo, 0, 0);

    captureCanvas.toBlob((blob) => {
      if (blob && dataChannelOpen && dataChannel && dataChannel.readyState === 'open') {
        blob.arrayBuffer().then(buffer => {
          // Frame format: [width: u32 LE][height: u32 LE][jpeg data]
          const header = new ArrayBuffer(8);
          const headerView = new DataView(header);
          headerView.setUint32(0, width, true);
          headerView.setUint32(4, height, true);

          const frame = new Uint8Array(8 + buffer.byteLength);
          frame.set(new Uint8Array(header), 0);
          frame.set(new Uint8Array(buffer), 8);

          try {
            dataChannel.send(frame.buffer);
          } catch (e) {
            // Channel might have closed
          }
        });
      }
    }, 'image/jpeg', 0.85);
  }, intervalMs);
}

function restartCaptureLoop() {
  if (isCapturing) {
    startCaptureLoop();
  }
}

// Listen for messages from background script (signaling from Zig via CDP)
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // RTC signaling from Zig
  if (message.type === 'RTC_SIGNAL') {
    handleSignaling(message.data);
    return false;
  }

  if (message.type === 'START_CAPTURE') {
    startCaptureWithStreamId(message.streamId).then(success => {
      sendResponse({ success });
    });
    return true;
  }

  if (message.type === 'STOP_CAPTURE') {
    stopCapture();
    closePeerConnection();
    sendResponse({ success: true });
    return false;
  }

  if (message.type === 'SET_FPS') {
    currentFps = Math.max(MIN_FPS, Math.min(MAX_FPS, message.fps));
    if (isCapturing) {
      restartCaptureLoop();
    }
    sendResponse({ fps: currentFps });
    return false;
  }

  return false;
});

// Signal that offscreen is ready
console.log('__TERMWEB_CAPTURE__:offscreen_ready');
