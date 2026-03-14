package middleware

import (
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	retailHTTPRequestCounter = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "retail_http_requests_total",
			Help: "Normalized HTTP request counter for Retail Store services.",
		},
		[]string{"application", "method", "route", "status"},
	)
	retailHTTPRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "retail_http_request_duration_seconds",
			Help:    "Normalized HTTP request duration histogram for Retail Store services.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"application", "method", "route", "status"},
	)
)

func MetricsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.URL.Path == "/metrics" {
			c.Next()
			return
		}

		start := time.Now()
		c.Next()

		route := c.FullPath()
		if route == "" {
			route = "unmatched"
		}

		status := strconv.Itoa(c.Writer.Status())
		labels := prometheus.Labels{
			"application": "catalog",
			"method":      c.Request.Method,
			"route":       route,
			"status":      status,
		}

		retailHTTPRequestCounter.With(labels).Inc()
		retailHTTPRequestDuration.With(labels).Observe(time.Since(start).Seconds())
	}
}
