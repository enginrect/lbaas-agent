package http

import (
	"log"
	"net/http"
	"strings"

	echo "github.com/labstack/echo/v4"

	"github.com/enginrect/lbaas-agent/ovs-agent/internal/adapters/ovnsb"
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/adapters/ovs"
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/usecase"
)

type Server struct {
	e   *echo.Echo
	ovn *ovnsb.LibOVNSB
	ovs *ovs.ExecOVS
}

func NewServer() (*Server, error) {
	ovn, err := ovnsb.NewLibOVNSB()
	if err != nil {
		return nil, err
	}
	ovsExec := ovs.NewExecOVS(executor.SubprocessExecutor{})
	e := echo.New()
	s := &Server{e: e, ovn: ovn, ovs: ovsExec}
	s.routes()
	return s, nil
}

func (s *Server) routes() {
	s.e.GET("/healthz", func(c echo.Context) error { return c.String(http.StatusOK, "ok") })
	s.e.POST("/flows", s.handleInsert)
	s.e.DELETE("/flows/:cookie", s.handleDelete)
}

type insertReq struct {
	CookieValue   string `json:"cookie_value"`
	NeutronPortID string `json:"bm_neutron_port_id"`
}

func (s *Server) handleInsert(c echo.Context) error {
	var req insertReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	if req.CookieValue == "" || req.NeutronPortID == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "cookie_value and bm_neutron_port_id are required"})
	}
	ctx, err := usecase.ResolveOVNContext(s.ovn, req.NeutronPortID)
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	if err := usecase.EnsureNoCookieConflict(s.ovs, req.CookieValue); err != nil {
		return c.JSON(http.StatusConflict, map[string]string{"error": err.Error()})
	}
	if err := usecase.EnsureNoMatchConflict(s.ovs, ctx); err != nil {
		return c.JSON(http.StatusConflict, map[string]string{"error": err.Error()})
	}
	res, err := usecase.AddFlowForContext(s.ovs, req.CookieValue, ctx)
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, res)
}

func (s *Server) handleDelete(c echo.Context) error {
	cookie := c.Param("cookie")
	if cookie == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "cookie is required"})
	}
	res, err := usecase.DeleteFlowByCookie(s.ovs, cookie)
	if err != nil {
		code := http.StatusBadRequest
		if strings.Contains(err.Error(), "not found") {
			code = http.StatusNotFound
		}
		if strings.Contains(err.Error(), "Too many") {
			code = http.StatusConflict
		}
		return c.JSON(code, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, res)
}

func (s *Server) Start(addr string) error {
	log.Printf("listening on %s", addr)
	return s.e.Start(addr)
}
